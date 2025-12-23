// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract MockERC20 is
    ERC20Pausable,
    Ownable,
    ERC20Burnable
{
    mapping(address => bool) public frozenAccounts;

    event Freeze(address indexed account);
    event Unfreeze(address indexed account);

    constructor(string memory name, string memory symbol)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        _mint(msg.sender, 1000 * 10**decimals());
    }

    // 冻结功能
    function freeze(address account) external onlyOwner {
        require(account != address(0), "Cannot freeze zero address");
        require(!frozenAccounts[account], "Account already frozen");
        frozenAccounts[account] = true;
        emit Freeze(account);
    }

    function unfreeze(address account) external onlyOwner {
        require(frozenAccounts[account], "Account not frozen");
        frozenAccounts[account] = false;
        emit Unfreeze(account);
    }

    function freezeMultiple(address[] memory accounts) external onlyOwner {
        for (uint i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Cannot freeze zero address");
            require(!frozenAccounts[accounts[i]], "Account already frozen");
            frozenAccounts[accounts[i]] = true;
            emit Freeze(accounts[i]);
        }
    }

    function unfreezeMultiple(address[] memory accounts) external onlyOwner {
        for (uint i = 0; i < accounts.length; i++) {
            require(frozenAccounts[accounts[i]], "Account not frozen");
            frozenAccounts[accounts[i]] = false;
            emit Unfreeze(accounts[i]);
        }
    }

    // 管理员铸造代币
    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Cannot mint to zero address");
        require(amount > 0, "Amount must be greater than 0");

        _mint(to, amount);
    }

    // 批量铸造代币
    function mintMultiple(address[] memory accounts, uint256[] memory amounts) external onlyOwner {
        require(accounts.length == amounts.length, "Arrays length mismatch");

        for (uint i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Cannot mint to zero address");
            require(amounts[i] > 0, "Amount must be greater than 0");

            _mint(accounts[i], amounts[i]);
        }
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Pausable) {
        // 检查冻结状态
        if (from != address(0)) {
            require(!frozenAccounts[from], "TokenTransfer: sender is frozen");
        }
        if (to != address(0)) {
            require(!frozenAccounts[to], "TokenTransfer: recipient is frozen");
        }

        // 调用父类 _update，ERC20Pausable 会自动检查暂停状态
        super._update(from, to, amount);
    }
}
