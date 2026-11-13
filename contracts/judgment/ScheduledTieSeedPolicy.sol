// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../interfaces/IGovernanceHub.sol";

interface IScheduledPolicyTimelock is IGovernanceHub {
    function getMinDelay() external view returns (uint256);
}

/// @notice Manually configured seed weights, recurring by New York session.
contract ScheduledTieSeedPolicy {
    uint16 public constant MIN_TIE_BPS = 500;
    uint16 public constant MAX_TIE_BPS = 2500;
    uint256 public constant MAX_CALENDAR_UPDATES = 64;
    address public immutable governanceHub;
    bytes32 public immutable marketId;

    enum Session {
        WeekdayCore,
        WeekdayOther,
        Weekend // Also used for explicitly closed exchange dates.
    }

    enum OverrideMode {
        Recurring,
        Closed,
        CustomWindow
    }

    struct DateOverride {
        OverrideMode mode;
        uint16 startMinute;
        uint16 endMinute;
    }

    uint16 public weekdayCoreTieBps;
    uint16 public weekdayOtherTieBps;
    uint16 public weekendTieBps;
    uint16 public weekdayStartMinute = 570;
    uint16 public weekdayEndMinute = 960;
    // NY civil-date ordinals, not UTC dates. Full-width keys avoid aliasing when
    // sessionFor accepts timestamps whose local day exceeds uint32.
    mapping(uint256 => DateOverride) public dateOverrides;

    error InvalidPolicy();
    error OnlyGovernance();
    error InvalidWeights();
    error InvalidCoreWindow();
    error InvalidCalendarUpdate();
    error PolicyNotConfigured();
    error UnsupportedTimestamp();

    event SessionTieBpsUpdated(
        uint16 weekdayCore,
        uint16 weekdayOther,
        uint16 weekend
    );
    event WeekdayCoreWindowUpdated(uint16 startMinute, uint16 endMinute);
    event DateOverrideUpdated(
        uint32 indexed localDay,
        OverrideMode mode,
        uint16 startMinute,
        uint16 endMinute
    );

    constructor(address hub, bytes32 market) {
        if (
            market == bytes32(0) ||
            hub.code.length == 0 ||
            IScheduledPolicyTimelock(hub).authorityEpoch() == 0 ||
            IScheduledPolicyTimelock(hub).getMinDelay() < 1 days
        ) revert InvalidPolicy();
        governanceHub = hub;
        marketId = market;
    }

    /// @dev Persists until another delayed governance update. Existing rounds
    /// retain their creation-time snapshots, including rounds started early.
    function setSessionTieBps(
        uint16 weekdayCore,
        uint16 weekdayOther,
        uint16 weekend
    ) external {
        if (msg.sender != governanceHub) revert OnlyGovernance();
        if (
            weekdayCore < MIN_TIE_BPS ||
            weekdayCore > MAX_TIE_BPS ||
            weekdayOther < MIN_TIE_BPS ||
            weekdayOther > MAX_TIE_BPS ||
            weekend < MIN_TIE_BPS ||
            weekend > MAX_TIE_BPS
        ) revert InvalidWeights();
        weekdayCoreTieBps = weekdayCore;
        weekdayOtherTieBps = weekdayOther;
        weekendTieBps = weekend;
        emit SessionTieBpsUpdated(weekdayCore, weekdayOther, weekend);
    }

    /// @notice Set a same-day New York interval [startMinute, endMinute).
    /// @dev 1440 is an exclusive midnight end; existing round snapshots persist.
    function setWeekdayCoreWindow(
        uint16 startMinute,
        uint16 endMinute
    ) external {
        if (msg.sender != governanceHub) revert OnlyGovernance();
        if (startMinute >= endMinute || endMinute > 1440)
            revert InvalidCoreWindow();
        weekdayStartMinute = startMinute;
        weekdayEndMinute = endMinute;
        emit WeekdayCoreWindowUpdated(startMinute, endMinute);
    }

    /// @notice Update 1..64 strictly increasing NY civil dates atomically.
    /// @dev Closed uses the weekend/offday profile. Recurring removes an override.
    /// Non-window modes require zero minutes. Custom windows cannot open weekends.
    /// Changes affect current previews and new snapshots, never existing rounds.
    function setDateOverrides(
        uint32[] calldata localDays,
        DateOverride[] calldata values
    ) external {
        if (msg.sender != governanceHub) revert OnlyGovernance();
        uint256 count = localDays.length;
        if (
            count == 0 || count > MAX_CALENDAR_UPDATES || count != values.length
        ) revert InvalidCalendarUpdate();
        for (uint256 i; i < count; ++i) {
            uint32 localDay = localDays[i];
            if (
                localDay < 1167609600 / 1 days ||
                (i != 0 && localDay <= localDays[i - 1])
            ) revert InvalidCalendarUpdate();
            DateOverride calldata value = values[i];
            if (value.mode == OverrideMode.CustomWindow) {
                uint256 weekday = (uint256(localDay) + 4) % 7;
                if (
                    weekday == 0 ||
                    weekday == 6 ||
                    value.startMinute >= value.endMinute ||
                    value.endMinute > 1440
                ) revert InvalidCalendarUpdate();
            } else if (value.startMinute != 0 || value.endMinute != 0) {
                revert InvalidCalendarUpdate();
            }
            if (value.mode == OverrideMode.Recurring)
                delete dateOverrides[localDay];
            else dateOverrides[localDay] = value;
            emit DateOverrideUpdated(
                localDay,
                value.mode,
                value.startMinute,
                value.endMinute
            );
        }
    }

    /// @notice Classify a scheduled start using CURRENT window/date overrides.
    /// Weekend (2) includes configured full-day exchange closures. Unlisted dates
    /// retain weekly rules; date exceptions do not recur or refresh automatically.
    function sessionFor(uint256 roundStart) public view returns (Session) {
        uint256 localTime = _newYorkTime(roundStart);
        uint256 localDay = localTime / 1 days;
        uint256 weekday = (localDay + 4) % 7;
        if (weekday == 0 || weekday == 6) return Session.Weekend;
        DateOverride memory value = dateOverrides[localDay];
        if (value.mode == OverrideMode.Closed) return Session.Weekend;
        uint16 startMinute = value.mode == OverrideMode.CustomWindow
            ? value.startMinute
            : weekdayStartMinute;
        uint16 endMinute = value.mode == OverrideMode.CustomWindow
            ? value.endMinute
            : weekdayEndMinute;
        uint256 minuteOfDay = (localTime % 1 days) / 1 minutes;
        return
            minuteOfDay >= startMinute && minuteOfDay < endMinute
                ? Session.WeekdayCore
                : Session.WeekdayOther;
    }

    /// @dev Current post-2007 US DST law; inputs are unambiguous UTC instants.
    function _newYorkTime(uint256 roundStart) private pure returns (uint256) {
        if (roundStart < 1167609600 || roundStart > type(uint64).max)
            revert UnsupportedTimestamp();
        uint256 utcDay = roundStart / 1 days;
        // Every Gregorian 400-year cycle has 146097 days. Ignoring leap days
        // overestimates the remaining year by at most one; correct against Jan 1.
        uint256 year = 1970 + (utcDay / 146097) * 400 + (utcDay % 146097) / 365;
        if (utcDay < _daysBeforeYear(year)) --year;
        uint256 yearStart = _daysBeforeYear(year);
        uint256 leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            ? 1
            : 0;
        uint256 march1 = yearStart + 59 + leap;
        uint256 november1 = yearStart + 304 + leap;
        // Sunday=0; second Sunday in March at 02:00 EST, first in November
        // at 02:00 EDT. Compare UTC instants so folds/gaps are unambiguous.
        uint256 dstStart = (march1 + 7 + ((7 - ((march1 + 4) % 7)) % 7)) *
            1 days +
            7 hours;
        uint256 dstEnd = (november1 + ((7 - ((november1 + 4) % 7)) % 7)) *
            1 days +
            6 hours;
        return
            roundStart -
            (roundStart >= dstStart && roundStart < dstEnd ? 4 hours : 5 hours);
    }

    function _daysBeforeYear(uint256 year) private pure returns (uint256) {
        uint256 previous = year - 1;
        // 477 leap days precede 1970 in the proleptic Gregorian calendar.
        return
            365 *
            (year - 1970) +
            previous /
            4 -
            previous /
            100 +
            previous /
            400 -
            477;
    }

    /// @notice Preview using CURRENT configuration; historical round weights
    /// must be read from the Judge's stored round, not recomputed here.
    function weightsFor(
        bytes32 market,
        uint256 roundStart,
        uint16 originalUp,
        uint16 originalDown,
        uint16 originalTie
    ) external view returns (uint16 up, uint16 down, uint16 tie) {
        if (market != marketId) return (originalUp, originalDown, originalTie);
        // The only setter validates and writes all three weights atomically.
        if (weekdayCoreTieBps == 0) revert PolicyNotConfigured();
        Session session = sessionFor(roundStart);
        tie = session == Session.WeekdayCore
            ? weekdayCoreTieBps
            : session == Session.WeekdayOther
                ? weekdayOtherTieBps
                : weekendTieBps;
        up = (10_000 - tie) / 2;
        down = 10_000 - tie - up;
    }
}
