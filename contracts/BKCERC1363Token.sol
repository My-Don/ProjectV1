// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC1363.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Spender.sol";

/**
 * @title BKCERC1363Token
 * @dev 支持冻结账户、批量铸造的 ERC1363 代币合约（OZ v5.1+）
 */
contract BKCERC1363Token is ERC20, Ownable, ERC165, ReentrancyGuard, IERC1363 {
    // ========== 错误定义 ==========

    error AccountFrozen(address account);
    error AccountNotFrozen(address account);
    error ZeroAddress();
    error ArrayLengthMismatch();
    error EmptyArray();
    error ExceedsMaxBatchSize(uint256 provided, uint256 max);
    error NotERC1363Receiver();
    error NotERC1363Spender();

    // ========== 事件 ==========

    event AccountFreeze(address indexed account, bool frozen);
    event BatchMint(
        address[] recipients,
        uint256[] amounts,
        uint256 totalMinted
    );

    // ========== 状态变量 ==========

    mapping(address => bool) private _frozen;
    uint256 public constant MAX_BATCH_SIZE = 200;

    // ========== 构造函数 ==========

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address owner
    ) ERC20(name, symbol) Ownable(owner) {
        if (owner == address(0)) revert ZeroAddress();
        if (initialSupply > 0) {
            _mint(owner, initialSupply * 10 ** decimals());
        }
    }

    // ========== ERC165 ==========

    /**
     * @notice 声明支持的接口
     * fix: 补充 IERC20 interfaceId 声明
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1363).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ========== 冻结功能 ==========

    /// @notice 冻结指定账户
    function freeze(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (_frozen[account]) revert AccountFrozen(account);
        _frozen[account] = true;
        emit AccountFreeze(account, true);
    }

    /// @notice 解冻指定账户
    function unfreeze(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (!_frozen[account]) revert AccountNotFrozen(account);
        _frozen[account] = false;
        emit AccountFreeze(account, false);
    }

    /// @notice 批量冻结账户
    function batchFreeze(address[] calldata accounts) external onlyOwner {
        if (accounts.length == 0) revert EmptyArray();
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            if (!_frozen[accounts[i]]) {
                _frozen[accounts[i]] = true;
                emit AccountFreeze(accounts[i], true);
            }
        }
    }

    /// @notice 查询账户是否被冻结
    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }

    // ========== 批量铸造 ==========

    /// @notice 批量铸造，每个地址指定数量（原始单位，需自行带精度）
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        if (recipients.length == 0) revert EmptyArray();
        if (recipients.length != amounts.length) revert ArrayLengthMismatch();
        if (recipients.length > MAX_BATCH_SIZE)
            revert ExceedsMaxBatchSize(recipients.length, MAX_BATCH_SIZE);

        uint256 totalMinted;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            _mint(recipients[i], amounts[i]);
            totalMinted += amounts[i];
        }

        emit BatchMint(recipients, amounts, totalMinted);
    }

    /// @notice 批量铸造同等数量给多个地址
    function batchMintEqual(
        address[] calldata recipients,
        uint256 amount
    ) external onlyOwner {
        if (recipients.length == 0) revert EmptyArray();
        if (recipients.length > MAX_BATCH_SIZE)
            revert ExceedsMaxBatchSize(recipients.length, MAX_BATCH_SIZE);

        uint256[] memory amounts = new uint256[](recipients.length);
        uint256 totalMinted = amount * recipients.length;

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            amounts[i] = amount;
            _mint(recipients[i], amount);
        }

        emit BatchMint(recipients, amounts, totalMinted);
    }

    /// @notice 单次铸造
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    // ========== 转账拦截（冻结检查） ==========

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from != address(0) && _frozen[from]) revert AccountFrozen(from);
        if (to != address(0) && _frozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }

    // ========== ERC1363 核心实现 ==========

    /// @inheritdoc IERC1363
    function transferAndCall(
        address to,
        uint256 value
    ) external override returns (bool) {
        return _transferAndCall(to, value, "");
    }

    /**
     * IERC1363
     * fix: 添加 nonReentrant 防止回调重入
     */
    function transferAndCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external override returns (bool) {
        return _transferAndCall(to, value, data);
    }

    function _transferAndCall(
        address to,
        uint256 value,
        bytes memory data
    ) internal nonReentrant returns (bool) {
        transfer(to, value);
        _checkOnTransferReceived(msg.sender, msg.sender, to, value, data);
        return true;
    }

    /// @inheritdoc IERC1363
    function transferFromAndCall(
        address from,
        address to,
        uint256 value
    ) external override returns (bool) {
        return _transferFromAndCall(from, to, value, "");
    }

    function transferFromAndCall(
        address from,
        address to,
        uint256 value,
        bytes calldata data
    ) external override returns (bool) {
        return _transferFromAndCall(from, to, value, data);
    }

    function _transferFromAndCall(
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal nonReentrant returns (bool) {
        transferFrom(from, to, value);
        _checkOnTransferReceived(msg.sender, from, to, value, data);
        return true;
    }

    /// @inheritdoc IERC1363
    function approveAndCall(
        address spender,
        uint256 value
    ) external override returns (bool) {
        return _approveAndCall(spender, value, "");
    }

    /**
     * IERC1363
     * notice: 添加 nonReentrant 防止回调重入
     * fix2: 回调结束后清零剩余授权，防止 allowance 残留被滥用
     */
    function approveAndCall(
        address spender,
        uint256 value,
        bytes calldata data
    ) external override returns (bool) {
        return _approveAndCall(spender, value, data);
    }

    function _approveAndCall(
        address spender,
        uint256 value,
        bytes memory data
    ) internal nonReentrant returns (bool) {
        approve(spender, value);
        _checkOnApprovalReceived(msg.sender, spender, value, data);

        // 清零剩余授权
        uint256 remaining = allowance(msg.sender, spender);
        if (remaining > 0) {
            approve(spender, 0);
        }

        return true;
    }

    // ========== 内部回调检查 ==========

    function _checkOnTransferReceived(
        address operator,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) return;
        try
            IERC1363Receiver(to).onTransferReceived(operator, from, value, data)
        returns (bytes4 retval) {
            if (retval != IERC1363Receiver.onTransferReceived.selector)
                revert NotERC1363Receiver();
        } catch {
            revert NotERC1363Receiver();
        }
    }

    function _checkOnApprovalReceived(
        address owner,
        address spender,
        uint256 value,
        bytes memory data
    ) internal {
        if (spender.code.length == 0) return;
        try
            IERC1363Spender(spender).onApprovalReceived(owner, value, data)
        returns (bytes4 retval) {
            if (retval != IERC1363Spender.onApprovalReceived.selector)
                revert NotERC1363Spender();
        } catch {
            revert NotERC1363Spender();
        }
    }
}
