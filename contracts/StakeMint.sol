// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Spender.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/**
 * @title StakeMint
 * @notice 质押挖矿合约，集成 Chainlink Automation + ERC1363
 * @dev 仅支持 ERC1363 一步质押，不支持传统 approve + transferFrom 流程
 *
 * 质押方式：
 *   方式一：token.transferAndCall(address(this), amount)
 *           → token 先转入合约，再回调 onTransferReceived 完成质押
 *   方式二：token.approveAndCall(address(this), amount)
 *           → 设置授权后回调 onApprovalReceived，合约主动拉款后完成质押
 */
contract StakeMint is
    Ownable,
    ReentrancyGuard,
    ERC165,
    AutomationCompatibleInterface,
    IERC1363Receiver,
    IERC1363Spender
{
    // ============ 错误定义 ============

    error OnlyUSDTAllowed(address caller);
    error InvalidStakeAmount(uint256 amount);
    error MiningNotStarted(address user);
    error TransferFromFailed();
    error InsufficientGBC();
    error InsufficientUSDT();

    // ============ 常量 ============

    address public immutable USDT;
    address public immutable GBC;

    uint256 public constant HASHRATE = 1e16;
    uint256 public constant BASICCOMPUTINGPOWER = 3e16;
    uint256 public constant TIMEINTERVAL = 24 hours;
    uint256 public constant UPDATE_INTERVAL = 1 hours;
    uint256 public constant MAX_HISTORY_LENGTH = 168;

    /// @notice 每次质押的最小单位（100个token，精度由构造时动态读取）
    uint256 public immutable STAKE_UNIT;

    // ============ Chainlink 相关 ============

    uint256 public lastUpdateTime;

    struct HashPowerSnapshot {
        uint256 timestamp;
        uint256 totalHashPower;
        uint256 totalStakedUsdt;
        uint256 totalMiners;
        uint256 blockNumber;
    }

    HashPowerSnapshot[] public hashPowerHistory;
    uint256 public totalStakedUsdt;
    uint256 public totalActiveMiners;

    // ============ 矿工相关 ============

    struct Minter {
        bool isStartMint;
        uint256 startMintTime;
        uint256 totalUsdt;
        uint256 lastMintTime;
    }

    mapping(address => Minter) public minter;
    address[] public minerAddresses;
    mapping(address => bool) public isMinerRegistered;

    // ============ 修饰符 ============

    modifier OnlyEOA() {
        require(msg.sender == tx.origin, "Only EOA");
        _;
    }

    // ============ 事件 ============

    event StartMint(
        address indexed owner,
        bool isStartMint,
        uint256 startMintTime,
        uint256 lastMintTime
    );
    event Staked(address indexed owner, uint256 amount, uint256 totalUsdt);
    event WithdrawRewards(address indexed owner, uint256 reward);
    event WithdrawStake(address indexed user, uint256 amount);
    event HashPowerUpdated(
        uint256 indexed snapshotId,
        uint256 timestamp,
        uint256 totalHashPower,
        uint256 totalStakedUsdt,
        uint256 totalMiners
    );
    event StakedViaTransferAndCall(
        address indexed from,
        address indexed operator,
        uint256 amount
    );
    event StakedViaApproveAndCall(address indexed from, uint256 amount);

    // ============ 构造函数 ============

    constructor(address usdt, address gbc) Ownable(msg.sender) {
        USDT = usdt;
        GBC = gbc;

        // 动态读取 token 精度，兼容任意精度的 ERC1363 token
        (, bytes memory data) = usdt.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        uint8 dec = abi.decode(data, (uint8));
        STAKE_UNIT = 100 * (10 ** dec);

        lastUpdateTime = block.timestamp;
        _createHashPowerSnapshot();
    }

    // ============ ERC165 ============

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC165) returns (bool) {
        return
            interfaceId == type(IERC1363Receiver).interfaceId ||
            interfaceId == type(IERC1363Spender).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ IERC1363Receiver — transferAndCall 回调 ============

    /**
     * @inheritdoc IERC1363Receiver
     * @notice 用户调用 token.transferAndCall(address(this), amount) 触发
     * @dev    token 已在回调前完成转账，此处直接执行质押逻辑，无需再拉款
     *
     *  调用链：
     *    用户 → token.transferAndCall()
     *      → token._update()          // token 转入本合约
     *      → onTransferReceived()     // 本函数：执行质押
     */
    function onTransferReceived(
        address operator,
        address from,
        uint256 value,
        bytes calldata
    ) external override nonReentrant returns (bytes4) {
        if (msg.sender != USDT) revert OnlyUSDTAllowed(msg.sender);

        // token 已到账，直接质押
        _stake(from, value);

        emit StakedViaTransferAndCall(from, operator, value);

        return IERC1363Receiver.onTransferReceived.selector;
    }

    // ============ IERC1363Spender — approveAndCall 回调 ============

    /**
     * @inheritdoc IERC1363Spender
     * @notice 用户调用 token.approveAndCall(address(this), amount) 触发
     * @dev    approveAndCall 仅设置授权后回调，token 未转账，需主动拉款
     *
     *  调用链：
     *    用户 → token.approveAndCall()
     *      → token.approve()          // 设置授权
     *      → onApprovalReceived()     // 本函数：拉款 + 质押
     */
    function onApprovalReceived(
        address owner,
        uint256 value,
        bytes calldata
    ) external override nonReentrant returns (bytes4) {
        if (msg.sender != USDT) revert OnlyUSDTAllowed(msg.sender);

        // token 未到账，先拉款再质押
        _transferFromUser(owner, value);
        _stake(owner, value);

        emit StakedViaApproveAndCall(owner, value);

        return IERC1363Spender.onApprovalReceived.selector;
    }

    // ============ Chainlink Automation ============

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(
        bytes calldata
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - lastUpdateTime) >= UPDATE_INTERVAL;
        performData = "";
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata) external override {
        if ((block.timestamp - lastUpdateTime) >= UPDATE_INTERVAL) {
            _createHashPowerSnapshot();
            lastUpdateTime = block.timestamp;
        }
    }

    // ============ 对外功能函数 ============

    /// @notice 开始挖矿（必须先调用，才能质押）
    function startMint() external OnlyEOA nonReentrant {
        address user = msg.sender;
        Minter storage m = minter[user];
        require(!m.isStartMint, "Mining started");

        m.startMintTime = block.timestamp;
        m.lastMintTime = block.timestamp;
        m.isStartMint = true;

        _registerMiner(user);

        emit StartMint(user, true, m.startMintTime, m.lastMintTime);
    }

    /// @notice 领取挖矿奖励
    function withdrawRewards() external OnlyEOA nonReentrant {
        _withdrawRewards(msg.sender);
    }

    /// @notice 赎回质押的 token
    function withdrawStakeUsdt(uint256 amount) external OnlyEOA nonReentrant {
        address user = msg.sender;
        Minter storage m = minter[user];
        require(m.isStartMint && m.startMintTime > 0, "Mining not started");
        require(amount > 0 && amount <= m.totalUsdt, "Invalid amount");

        // 赎回前先结算奖励
        if (block.timestamp >= m.lastMintTime + TIMEINTERVAL) {
            _withdrawRewards(user);
        }

        m.totalUsdt -= amount;
        totalStakedUsdt -= amount;

        // 查询合约余额
        (bool s, bytes memory d) = USDT.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        if (!s || d.length == 0 || abi.decode(d, (uint256)) < amount)
            revert InsufficientUSDT();

        // 转还用户
        (bool ok, bytes memory res) = USDT.call(
            abi.encodeWithSelector(0xa9059cbb, user, amount)
        );
        require(
            ok && (res.length == 0 || abi.decode(res, (bool))),
            "Transfer failed"
        );

        emit WithdrawStake(user, amount);
    }

    // ============ 查询函数 ============

    function getPower(address user) public view returns (uint256) {
        return
            BASICCOMPUTINGPOWER +
            (minter[user].totalUsdt / STAKE_UNIT) *
            HASHRATE;
    }

    function pendingRewards(
        address user
    ) public view returns (uint256 reward, uint256 power) {
        Minter storage m = minter[user];
        if (!m.isStartMint || m.startMintTime == 0) return (0, 0);
        if (block.timestamp < m.lastMintTime + TIMEINTERVAL)
            return (0, getPower(user));
        uint256 passHours = (block.timestamp - m.lastMintTime) / 1 hours;
        power = getPower(user);
        reward = power * passHours;
    }

    function getHashPowerHistoryLength() external view returns (uint256) {
        return hashPowerHistory.length;
    }

    function getHashPowerSnapshot(
        uint256 index
    )
        external
        view
        returns (
            uint256 timestamp,
            uint256 totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        )
    {
        require(index < hashPowerHistory.length, "Out of bounds");
        HashPowerSnapshot memory s = hashPowerHistory[index];
        return (
            s.timestamp,
            s.totalHashPower,
            s.totalStakedUsdt,
            s.totalMiners,
            s.blockNumber
        );
    }

    function getLatestHashPowerSnapshot()
        external
        view
        returns (
            uint256 timestamp,
            uint256 totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        )
    {
        require(hashPowerHistory.length > 0, "No snapshots");
        HashPowerSnapshot memory s = hashPowerHistory[
            hashPowerHistory.length - 1
        ];
        return (
            s.timestamp,
            s.totalHashPower,
            s.totalStakedUsdt,
            s.totalMiners,
            s.blockNumber
        );
    }

    function getRecentHashPowerSnapshots(
        uint256 count
    ) external view returns (HashPowerSnapshot[] memory) {
        require(count > 0, "Count must > 0");
        uint256 len = hashPowerHistory.length;
        uint256 n = count > len ? len : count;
        HashPowerSnapshot[] memory result = new HashPowerSnapshot[](n);
        for (uint256 i = 0; i < n; i++) {
            result[i] = hashPowerHistory[len - n + i];
        }
        return result;
    }

    function getCurrentTotalHashPower() external view returns (uint256) {
        return _calculateTotalHashPower();
    }

    function getTotalMiners() external view returns (uint256) {
        return minerAddresses.length;
    }

    function getActiveMiners() external view returns (uint256) {
        return totalActiveMiners;
    }

    // ============ 管理员函数 ============

    function manualUpdateHashPower() external onlyOwner {
        _createHashPowerSnapshot();
        lastUpdateTime = block.timestamp;
    }

    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        require(token != address(0) && amount > 0, "Invalid params");
        (bool ok, ) = token.call(
            abi.encodeWithSelector(0xa9059cbb, owner(), amount)
        );
        require(ok, "Transfer failed");
    }

    // ============ 内部函数 ============

    function _stake(address user, uint256 amount) internal {
        Minter storage m = minter[user];
        if (!m.isStartMint || m.startMintTime == 0)
            revert MiningNotStarted(user);
        if (amount == 0 || amount % STAKE_UNIT != 0)
            revert InvalidStakeAmount(amount);

        // 奖励结算失败不阻断质押
        if (block.timestamp >= m.lastMintTime + TIMEINTERVAL) {
            try this.externalWithdrawRewards(user) {} catch {}
        }

        m.totalUsdt += amount;
        totalStakedUsdt += amount;

        emit Staked(user, amount, m.totalUsdt);
    }

    // 包装为 external 供 try/catch 调用
    function externalWithdrawRewards(address user) external {
        require(msg.sender == address(this), "Internal only");
        _withdrawRewards(user);
    }

    function _withdrawRewards(address user) internal {
        Minter storage m = minter[user];
        require(m.isStartMint && m.startMintTime > 0, "Mining not started");
        require(
            block.timestamp >= m.lastMintTime + TIMEINTERVAL,
            "Not time yet"
        );

        (uint256 reward, ) = pendingRewards(user);
        require(reward > 0, "No rewards");

        (bool s, bytes memory d) = GBC.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        if (!s || d.length == 0 || abi.decode(d, (uint256)) < reward)
            revert InsufficientGBC();

        m.lastMintTime =
            m.lastMintTime +
            ((block.timestamp - m.lastMintTime) / 1 hours) *
            1 hours;

        (bool ok, ) = GBC.call(
            abi.encodeWithSelector(0xa9059cbb, user, reward)
        );
        require(ok, "GBC transfer failed");

        emit WithdrawRewards(user, reward);
    }

    /// @dev 仅用于 onApprovalReceived，从用户账户拉款到本合约
    function _transferFromUser(address from, uint256 amount) internal {
        (bool ok, bytes memory res) = USDT.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                from,
                address(this),
                amount
            )
        );
        if (!ok || (res.length > 0 && !abi.decode(res, (bool))))
            revert TransferFromFailed();
    }

    function _registerMiner(address minerAddr) internal {
        if (!isMinerRegistered[minerAddr]) {
            minerAddresses.push(minerAddr);
            isMinerRegistered[minerAddr] = true;
            totalActiveMiners++;
        }
    }

    function _createHashPowerSnapshot() internal {
        uint256 totalPower = _calculateTotalHashPower();

        HashPowerSnapshot memory snapshot = HashPowerSnapshot({
            timestamp: block.timestamp,
            totalHashPower: totalPower,
            totalStakedUsdt: totalStakedUsdt,
            totalMiners: totalActiveMiners,
            blockNumber: block.number
        });

        if (hashPowerHistory.length >= MAX_HISTORY_LENGTH) {
            for (uint256 i = 0; i < hashPowerHistory.length - 1; i++) {
                hashPowerHistory[i] = hashPowerHistory[i + 1];
            }
            hashPowerHistory.pop();
        }

        hashPowerHistory.push(snapshot);

        emit HashPowerUpdated(
            hashPowerHistory.length - 1,
            snapshot.timestamp,
            snapshot.totalHashPower,
            snapshot.totalStakedUsdt,
            snapshot.totalMiners
        );
    }

    function _calculateTotalHashPower() internal view returns (uint256 total) {
        for (uint256 i = 0; i < minerAddresses.length; i++) {
            address addr = minerAddresses[i];
            if (minter[addr].isStartMint) {
                total += getPower(addr);
            }
        }
    }
}
