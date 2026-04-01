// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title WikiPushNotification
 * @notice On-chain notification preference registry.
 *         Users register their FCM/APNS device token once.
 *         Contracts emit events → backend sends push notifications.
 *
 * NOTIFICATION TYPES:
 *   HEALTH_WARNING:     Position health < 20%
 *   HEALTH_CRITICAL:    Position health < 10%
 *   LIQUIDATION:        Position liquidated
 *   CONDITIONAL_FIRED:  Conditional order triggered
 *   PROP_DEADLINE:      Prop challenge ending in 3 days
 *   PROP_PASSED:        Phase 1 or Phase 2 passed
 *   PROP_FAILED:        Challenge failed
 *   PRICE_ALERT:        Custom price alert triggered
 *   SEASON_ENDING:      XP season ends in 7 days
 *   PROTECTION_ADDED:   Liq protection auto-added margin
 *   FUNDING_RATE:       Funding rate exceeds threshold (for bot users)
 */
contract WikiPushNotification is Ownable2Step {

    enum NotifType {
        HEALTH_WARNING, HEALTH_CRITICAL, LIQUIDATION,
        CONDITIONAL_FIRED, PROP_DEADLINE, PROP_PASSED, PROP_FAILED,
        PRICE_ALERT, SEASON_ENDING, PROTECTION_ADDED, FUNDING_RATE
    }

    struct NotifPreferences {
        bool    enabled;
        bool[11] types;          // which notification types enabled
        uint256 healthThreshold; // alert when health < this BPS
        uint256 registeredAt;
        uint256 lastNotifTs;
    }

    mapping(address => NotifPreferences) public preferences;
    mapping(address => bool)             public recorders;

    // Events consumed by notification backend
    event NotificationRequested(
        address indexed user,
        NotifType notifType,
        string  payload,         // JSON string with notification details
        uint256 timestamp
    );
    event DeviceRegistered(address indexed user, uint256 timestamp);
    event PreferencesUpdated(address indexed user);

    constructor(address _owner) Ownable(_owner) { recorders[_owner] = true; }

    // ── User registration ─────────────────────────────────────────────────
    function register(uint256 healthThreshold, bool[11] calldata enabledTypes) external {
        preferences[msg.sender] = NotifPreferences({
            enabled:         true,
            types:           enabledTypes,
            healthThreshold: healthThreshold > 0 ? healthThreshold : 2000, // default 20%
            registeredAt:    block.timestamp,
            lastNotifTs:     0
        });
        emit DeviceRegistered(msg.sender, block.timestamp);
    }

    function updatePreferences(bool enabled, bool[11] calldata types, uint256 threshold) external {
        NotifPreferences storage p = preferences[msg.sender];
        p.enabled         = enabled;
        p.types           = types;
        p.healthThreshold = threshold;
        emit PreferencesUpdated(msg.sender);
    }

    function unregister() external {
        preferences[msg.sender].enabled = false;
    }

    // ── Emit notifications (called by protocol contracts/keeper) ─────────
    function notify(address user, NotifType notifType, string calldata payload) external {
        require(recorders[msg.sender], "PN: not recorder");
        NotifPreferences storage p = preferences[user];
        if (!p.enabled) return;
        if (!p.types[uint8(notifType)]) return;
        // Rate limit: max 1 notification per minute per user
        if (block.timestamp < p.lastNotifTs + 60) return;
        p.lastNotifTs = block.timestamp;
        emit NotificationRequested(user, notifType, payload, block.timestamp);
    }

    function batchNotify(address[] calldata users, NotifType notifType, string calldata payload) external {
        require(recorders[msg.sender], "PN: not recorder");
        for (uint i; i < users.length; i++) {
            NotifPreferences storage p = preferences[users[i]];
            if (!p.enabled || !p.types[uint8(notifType)]) continue;
            if (block.timestamp < p.lastNotifTs + 60) continue;
            p.lastNotifTs = block.timestamp;
            emit NotificationRequested(users[i], notifType, payload, block.timestamp);
        }
    }

    // ── Views ─────────────────────────────────────────────────────────────
    function isRegistered(address user) external view returns (bool) { return preferences[user].enabled; }
    function getPreferences(address user) external view returns (NotifPreferences memory) { return preferences[user]; }
    function wantsNotif(address user, NotifType t) external view returns (bool) {
        NotifPreferences storage p = preferences[user];
        return p.enabled && p.types[uint8(t)];
    }

    function setRecorder(address r, bool on) external onlyOwner { recorders[r] = on; }
}
