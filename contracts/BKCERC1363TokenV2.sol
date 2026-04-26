// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1363} from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/**
 * @title BKCERC1363Token
 * @dev ERC20 + ERC1363 token with role-based minting, capped supply, and account freezing.
 *
 * 注意：
 * - 所有 initialSupplyRaw / maxSupplyRaw / amount 参数都是“最小单位”，也就是已经带 decimals 的 raw units。
 * - 例如 1 个 token，18 位精度时，应传 1e18。
 * - 如果要部署 1,000,000 个 token，18 位精度时，应传 1_000_000 * 1e18。
 */
contract BKCERC1363Token is ERC1363, ERC20Capped, AccessControlDefaultAdminRules {
    // ========== Roles ==========

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");

    // ========== Errors ==========

    error AccountFrozen(address account);
    error AccountNotFrozen(address account);
    error ZeroAddress();
    error ZeroAmount();
    error EmptyArray();
    error ArrayLengthMismatch();
    error ExceedsMaxBatchSize(uint256 provided, uint256 max);
    error InitialSupplyExceedsCap(uint256 initialSupply, uint256 cap);
    error FrozenAccountsRemain(uint256 frozenCount);

    // ========== Events ==========

    event AccountFreeze(address indexed account, bool frozen);
    event BatchFreeze(bool frozen, uint256 providedCount, uint256 changedCount);
    event BatchMint(uint256 recipientsCount, uint256 totalMinted);
    event BatchMintEqual(uint256 recipientsCount, uint256 amountEach, uint256 totalMinted);

    // ========== Storage ==========

    mapping(address account => bool frozen) private _frozen;
    uint256 private _frozenCount;

    uint256 public constant MAX_BATCH_SIZE = 200;

    // ========== Constructor ==========

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupplyRaw,
        uint256 maxSupplyRaw,
        address admin,
        uint48 adminTransferDelay
    )
        ERC20(name_, symbol_)
        ERC20Capped(maxSupplyRaw)
        AccessControlDefaultAdminRules(adminTransferDelay, admin)
    {
        if (initialSupplyRaw > maxSupplyRaw) {
            revert InitialSupplyExceedsCap(initialSupplyRaw, maxSupplyRaw);
        }

        _grantRole(MINTER_ROLE, admin);
        _grantRole(FREEZER_ROLE, admin);

        if (initialSupplyRaw > 0) {
            _mint(admin, initialSupplyRaw);
        }
    }

    // ========== Views ==========

    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }

    function frozenCount() external view returns (uint256) {
        return _frozenCount;
    }

    // ========== Freeze / Unfreeze ==========

    function freeze(address account) external onlyRole(FREEZER_ROLE) {
        if (!_setFrozen(account, true)) revert AccountFrozen(account);
    }

    function unfreeze(address account) external onlyRole(FREEZER_ROLE) {
        if (!_setFrozen(account, false)) revert AccountNotFrozen(account);
    }

    function batchFreeze(address[] calldata accounts) external onlyRole(FREEZER_ROLE) {
        uint256 changed = _batchSetFrozen(accounts, true);
        emit BatchFreeze(true, accounts.length, changed);
    }

    function batchUnfreeze(address[] calldata accounts) external onlyRole(FREEZER_ROLE) {
        uint256 changed = _batchSetFrozen(accounts, false);
        emit BatchFreeze(false, accounts.length, changed);
    }

    // ========== Mint ==========

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);
    }

    function batchMint(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) {
        uint256 length = recipients.length;

        _checkBatchLength(length);

        if (length != amounts.length) revert ArrayLengthMismatch();

        uint256 totalMinted;

        for (uint256 i = 0; i < length; ) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];

            if (recipient == address(0)) revert ZeroAddress();
            if (amount == 0) revert ZeroAmount();

            totalMinted += amount;
            _mint(recipient, amount);

            unchecked {
                ++i;
            }
        }

        emit BatchMint(length, totalMinted);
    }

    function batchMintEqual(
        address[] calldata recipients,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        uint256 length = recipients.length;

        _checkBatchLength(length);

        if (amount == 0) revert ZeroAmount();

        uint256 totalMinted = amount * length;

        for (uint256 i = 0; i < length; ) {
            address recipient = recipients[i];

            if (recipient == address(0)) revert ZeroAddress();

            _mint(recipient, amount);

            unchecked {
                ++i;
            }
        }

        emit BatchMintEqual(length, amount, totalMinted);
    }

    // ========== Admin Safety ==========

    /**
     * @dev 防止存在冻结账户时，最后的 DEFAULT_ADMIN_ROLE 被放弃。
     * 否则会出现冻结账户永久无法解冻的问题。
     */
    function renounceRole(
        bytes32 role,
        address account
    ) public override(AccessControlDefaultAdminRules) {
        if (role == DEFAULT_ADMIN_ROLE && account == defaultAdmin() && _frozenCount > 0) {
            revert FrozenAccountsRemain(_frozenCount);
        }

        super.renounceRole(role, account);
    }

    // ========== Overrides ==========

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1363, AccessControlDefaultAdminRules) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Capped) {
        if (from != address(0) && _frozen[from]) revert AccountFrozen(from);
        if (to != address(0) && _frozen[to]) revert AccountFrozen(to);

        super._update(from, to, value);
    }

    // ========== Internal Helpers ==========

    function _batchSetFrozen(
        address[] calldata accounts,
        bool frozen
    ) private returns (uint256 changed) {
        uint256 length = accounts.length;

        _checkBatchLength(length);

        for (uint256 i = 0; i < length; ) {
            if (_setFrozen(accounts[i], frozen)) {
                unchecked {
                    ++changed;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _setFrozen(address account, bool frozen) private returns (bool changed) {
        if (account == address(0)) revert ZeroAddress();

        bool current = _frozen[account];

        if (current == frozen) {
            return false;
        }

        _frozen[account] = frozen;

        if (frozen) {
            unchecked {
                ++_frozenCount;
            }
        } else {
            unchecked {
                --_frozenCount;
            }
        }

        emit AccountFreeze(account, frozen);

        return true;
    }

    function _checkBatchLength(uint256 length) private pure {
        if (length == 0) revert EmptyArray();
        if (length > MAX_BATCH_SIZE) revert ExceedsMaxBatchSize(length, MAX_BATCH_SIZE);
    }
}