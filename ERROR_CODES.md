# VoxChapter Error Code Reference

To reduce contract size below the 24KB limit, all error messages in VoxChapter.sol have been shortened to 3-5 character codes.

## Error Code Mapping

| Code   | Full Error Message          | Description                                     |
| ------ | --------------------------- | ----------------------------------------------- |
| `INIT` | Already initialized         | Contract has already been initialized           |
| `AUTH` | Not authorized / Only owner | Caller lacks required permissions               |
| `RMV`  | Chapter has been removed    | Chapter is in removed state                     |
| `BAN`  | Chapter/User is banned      | Banned status check failed                      |
| `ADDR` | Invalid address             | Zero address or invalid address provided        |
| `OWN`  | Cannot ban chapter owner    | Attempted to ban the chapter owner              |
| `SUB`  | SubMod related error        | SubMod already exists, not found, or invalid    |
| `INV`  | Invitation related error    | No pending invitation or already pending        |
| `MAX`  | Maximum limit reached       | Maximum subMods limit exceeded                  |
| `BAL`  | Balance/threshold error     | Insufficient balance or below minimum threshold |
| `POL`  | POL transfer failed         | Native token transfer failed                    |
| `USDC` | USDC not configured         | USDC address not set                            |
| `SHR`  | Share out of range          | Share value must be between 0-100               |

## Common Error Scenarios

### Authorization Errors (`AUTH`)

- Only platform owner can call this function
- Only chapter owner can call this function
- Only diamond contract can call this function
- Caller not authorized (chapter owner or platform owner)

### Ban Errors (`BAN`)

- Chapter is banned
- User is banned at platform level
- User is banned from this chapter
- New admin is banned
- Chapter is not banned (for unban operations)

### Address Errors (`ADDR`)

- Invalid address (zero address)
- Cannot ban/unban zero address

### SubMod Errors (`SUB`)

- Already a subMod
- Not a subMod
- Address is not a subMod
- Address is already a subMod in another chapter
- New admin must be a current subMod

### Invitation Errors (`INV`)

- No pending invitation
- Invitation already pending

### State Errors

- `INIT`: Already initialized
- `RMV`: Chapter has been removed
- `MAX`: Maximum subMods reached (150 max)

### Balance Errors (`BAL`)

- Insufficient balance: need at least minimum threshold
- No rewards available to distribute

### Transfer Errors

- `POL`: POL transfer failed
- `USDC`: USDC not configured

### Share Errors (`SHR`)

- Share must be between 0 and 100

## Size Optimization Results

**Before Optimization:**

- Contract Size: 24.382 KiB
- Status: ❌ Exceeded 24KB limit by ~391 bytes

**After Optimization:**

- Contract Size: 22.818 KiB
- Status: ✅ Under 24KB limit
- Savings: **1.563 KiB** (~1,601 bytes saved)

## For Developers

When debugging:

1. Check the error code from the transaction revert
2. Reference this document for the full error message
3. Look at the function context to understand which specific check failed

Example:

```solidity
// Transaction reverts with: "AUTH"
// Possible causes:
// - Not the chapter owner
// - Not the platform owner
// - Not authorized to perform this action
```

## Testing Considerations

When writing tests, use the shortened error codes:

```javascript
// Old:
await expect(chapter.revokeChapterAdmin()).to.be.revertedWith(
  "Only platform owner",
);

// New:
await expect(chapter.revokeChapterAdmin()).to.be.revertedWith("AUTH");
```
