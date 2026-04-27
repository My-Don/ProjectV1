// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {IERC1363Spender} from "@openzeppelin/contracts/interfaces/IERC1363Spender.sol";

import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/**
 * @title StakeMint
 * @notice ERC1363 一步质押挖矿合约，集成 Chainlink Automation 快照。
 *
 * @dev 质押方式：
 * 1. 用户先调用 startMint()
 * 2. 然后调用 USDT.transferAndCall(address(this), amount)
 *    或 USDT.approveAndCall(address(this), amount)
 *
 * 重要设计：
 * - 不支持传统 approve + 手动 transferFrom 质押。
 * - USDT / GBC 必须使用非 fee-on-transfer / 非 deflationary 实现。
 * - approveAndCall 和 fundRewards 会严格拒绝 fee-on-transfer；
 *   transferAndCall 因 ERC1363 标准回调发生在转账后，只能做偿付能力校验。
 * - 未质押不产生基础算力，避免零成本 Sybil 挖矿。
 * - 暂停后禁止 startMint、质押、领取奖励，但仍允许赎回 USDT 本金。
 * - GBC 余额不足时，用户领取奖励失败，但不影响赎回本金。
 * - 用户全额赎回时，会清除不足 1 个 GBC 最小单位的奖励余数。
 * - owner 不能提走用户质押本金，只能救援 USDT 超额余额或非保护 token。
 * - Chainlink Automation Forwarder 可选配置，注册 Upkeep 后再设置。
 */
contract StakeMint is
    Ownable2Step,
    ReentrancyGuard,
    Pausable,
    ERC165,
    AutomationCompatibleInterface,
    IERC1363Receiver,
    IERC1363Spender
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ============ Errors ============

    error OnlyUSDTAllowed(address caller);
    error InvalidStakeAmount(uint256 amount);
    error InvalidWithdrawAmount(uint256 amount);
    error InvalidAmount(uint256 amount);
    error MiningNotStarted(address user);
    error MiningAlreadyStarted(address user);
    error ClaimTooSoon(uint256 nextClaimTime);
    error NoRewards();
    error InsufficientGBC(uint256 required, uint256 available);
    error InsufficientUSDT(uint256 required, uint256 available);
    error InvalidTokenAddress(address token);
    error InvalidTokenDecimals(uint8 decimals_);
    error CountMustBePositive();
    error IndexOutOfBounds(uint256 index, uint256 length);
    error NoSnapshots();
    error UpkeepNotNeeded(uint256 lastUpdateTime, uint256 currentTime);
    error ProtectedToken(address token);
    error RescueAmountTooLarge(uint256 requested, uint256 available);
    error ZeroAddress();
    error TransferAmountMismatch(uint256 expected, uint256 received);
    error ActiveMinerCounterUnderflow();
    error UnauthorizedUpkeepCaller(address caller);

    // ============ Token ============

    IERC20 public immutable USDT;
    IERC20 public immutable GBC;

    // ============ Mining Config ============

    ///  合约版本号，方便前端、脚本和区块浏览器识别当前部署版本。
    string public constant CONTRACT_VERSION = "1.0.0";

    uint8 public immutable GBC_DECIMALS;

    /**
     * @notice 每 100 USDT 质押单位每小时产生的 GBC 最小单位奖励。
     * @dev 如果 GBC 是 18 decimals，则为 0.01 GBC / hour。
     */
    uint256 public immutable HASHRATE;

    /**
     * @notice 有效质押用户的基础每小时 GBC 最小单位奖励。
     * @dev 如果 GBC 是 18 decimals，则为 0.03 GBC / hour。
     */
    uint256 public immutable BASICCOMPUTINGPOWER;

    /// @notice 最短领奖间隔。
    uint256 public constant TIMEINTERVAL = 24 hours;

    /// @notice Chainlink Automation 快照间隔。
    uint256 public constant UPDATE_INTERVAL = 1 hours;

    /// @notice 最多保存最近 168 条快照，约 7 天，每小时一条。
    uint256 public constant MAX_HISTORY_LENGTH = 168;

    /// @notice 每次质押单位：100 个 USDT，精度由 USDT decimals 动态确定。
    uint256 public immutable STAKE_UNIT;

    // ============ Chainlink Snapshot ============

    uint256 public lastUpdateTime;

    /**
     * @notice Chainlink Automation Forwarder 地址。
     * @dev address(0) 表示不限制 performUpkeep 调用者。
     *      Upkeep 注册完成后，可以由 owner 设置为 Chainlink Forwarder 地址。
     */
    address public automationForwarder;

    struct HashPowerSnapshot {
        uint256 timestamp;
        uint256 totalHashPower;
        uint256 totalStakedUsdt;
        uint256 totalMiners;
        uint256 blockNumber;
    }

    HashPowerSnapshot[MAX_HISTORY_LENGTH] private _hashPowerHistory;

    uint256 private _nextSnapshotIndex;

    /// @notice 当前保存的快照数量，最大为 MAX_HISTORY_LENGTH。
    uint256 public hashPowerHistoryLength;

    /// @notice 历史快照总计数，单调递增，用于事件 snapshotId。
    uint256 public snapshotCounter;

    // ============ Global Mining State ============

    uint256 public totalStakedUsdt;
    uint256 public totalActiveMiners;
    uint256 public totalHashPower;

    // ============ Miner State ============

    /**
     * @dev Slot packing:
     * - slot 0: bool + uint48 + uint48 + uint48 + uint32
     * - slot 1: totalUsdt
     * - slot 2: accruedRewards
     *
     * 注意：public mapping 自动生成的 minter(address) getter 会按本 struct 字段顺序返回。
     * 前端建议使用 getMinter(address) 聚合视图函数。
     */
    struct Minter {
        bool isStartMint;
        uint48 startMintTime;
        uint48 lastMintTime;
        uint48 lastClaimTime;
        uint32 rewardRemainder;
        uint256 totalUsdt;
        uint256 accruedRewards;
    }

    mapping(address => Minter) public minter;

    /**
     * @notice 历史注册过的矿工地址。
     * @dev 不会因为用户全部赎回而删除，避免数组删除成本。
     *      当前合约不会在写操作中遍历该数组，避免矿工数量增长导致 gas 风险。
     */
    address[] public minerAddresses;

    mapping(address => bool) public isMinerRegistered;

    // ============ Events ============

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

    event RewardsFunded(address indexed from, uint256 amount);

    event TokenRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    event AutomationForwarderUpdated(
        address indexed oldForwarder,
        address indexed newForwarder
    );

    // ============ Constructor ============

    /**
     * @param usdt_ ERC1363 质押 token 地址。
     * @param gbc_ GBC 奖励 token 地址。
     * @param initialOwner_ 初始 owner，建议使用多签地址。
     */
    constructor(
        address usdt_,
        address gbc_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        if (initialOwner_ == address(0)) {
            revert ZeroAddress();
        }

        if (usdt_ == address(0) || usdt_.code.length == 0) {
            revert InvalidTokenAddress(usdt_);
        }

        if (gbc_ == address(0) || gbc_.code.length == 0) {
            revert InvalidTokenAddress(gbc_);
        }

        USDT = IERC20(usdt_);
        GBC = IERC20(gbc_);

        uint8 usdtDec = IERC20Metadata(usdt_).decimals();

        if (usdtDec > 36) {
            revert InvalidTokenDecimals(usdtDec);
        }

        STAKE_UNIT = 100 * (10 ** uint256(usdtDec));

        uint8 gbcDec = IERC20Metadata(gbc_).decimals();

        if (gbcDec < 2 || gbcDec > 36) {
            revert InvalidTokenDecimals(gbcDec);
        }

        GBC_DECIMALS = gbcDec;

        uint256 gbcUnit = 10 ** uint256(gbcDec);

        HASHRATE = gbcUnit / 100;
        BASICCOMPUTINGPOWER = (3 * gbcUnit) / 100;

        lastUpdateTime = block.timestamp;

        _createHashPowerSnapshot();
    }

    // ============ ERC165 ============

    /**
     * @notice 查询合约是否支持指定 interfaceId。
     * @param interfaceId ERC165 interface id。
     * @return supported 是否支持该接口。
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC165) returns (bool supported) {
        return
            interfaceId == type(IERC1363Receiver).interfaceId ||
            interfaceId == type(IERC1363Spender).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ ERC1363 Receiver: transferAndCall ============

    /**
     * @notice ERC1363 transferAndCall 回调。
     * @dev 用户调用 USDT.transferAndCall(address(this), amount) 后触发。
     *
     *      标准 ERC1363 回调发生在 token 转账之后，因此本函数无法读取本次转账前余额。
     *      为避免任何人直接转入 USDT 后造成 transferAndCall 路径被阻塞，本函数允许 surplus 存在，
     *      只要求当前余额足以覆盖“已记录质押本金 + 本次新增质押本金”。
     *
     *      运营建议：监控 getStakeTokenAccounting() 返回的 surplus / shortfall。
     *      - surplus > 0：说明存在误转或额外余额，owner 可用 rescueStakeTokenSurplus() 清理；
     *      - shortfall > 0：说明本金池不足，应立即暂停并排查。
     *
     *      如果需要严格校验本次到账数量，前端可优先引导用户使用 approveAndCall 路径。
     *
     * @param operator 调用 token transferAndCall 的地址。
     * @param from 实际质押用户地址。
     * @param value 质押数量。
     * @return selector IERC1363Receiver.onTransferReceived.selector。
     */
    function onTransferReceived(
        address operator,
        address from,
        uint256 value,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4 selector) {
        if (msg.sender != address(USDT)) {
            revert OnlyUSDTAllowed(msg.sender);
        }

        uint256 requiredBalance = totalStakedUsdt + value;
        uint256 currentBalance = USDT.balanceOf(address(this));

        if (currentBalance < requiredBalance) {
            revert InsufficientUSDT(requiredBalance, currentBalance);
        }

        _stakeAccounting(from, value);

        emit StakedViaTransferAndCall(from, operator, value);

        return IERC1363Receiver.onTransferReceived.selector;
    }

    // ============ ERC1363 Spender: approveAndCall ============

    /**
     * @notice ERC1363 approveAndCall 回调。
     * @dev 用户调用 USDT.approveAndCall(address(this), amount) 后触发。
     *      approveAndCall 只授权，不转账，所以这里主动 safeTransferFrom。
     *
     * @param owner_ 授权并质押的用户地址。
     * @param value 质押数量。
     * @return selector IERC1363Spender.onApprovalReceived.selector。
     */
    function onApprovalReceived(
        address owner_,
        uint256 value,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4 selector) {
        if (msg.sender != address(USDT)) {
            revert OnlyUSDTAllowed(msg.sender);
        }

        _validateStake(owner_, value);

        uint256 beforeBalance = USDT.balanceOf(address(this));

        USDT.safeTransferFrom(owner_, address(this), value);

        uint256 afterBalance = USDT.balanceOf(address(this));
        uint256 received = afterBalance - beforeBalance;

        if (received != value) {
            revert TransferAmountMismatch(value, received);
        }

        _stakeAccounting(owner_, value);

        emit StakedViaApproveAndCall(owner_, value);

        return IERC1363Spender.onApprovalReceived.selector;
    }

    // ============ Chainlink Automation ============

    /**
     * @notice Chainlink Automation 检查是否需要执行快照更新。
     * @param checkData Chainlink 传入的检查数据，本合约未使用。
     * @return upkeepNeeded 是否需要执行 performUpkeep。
     * @return performData 执行数据，本合约返回空 bytes。
     */
    function checkUpkeep(
        bytes calldata checkData
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        (checkData);
        upkeepNeeded = _upkeepNeeded();
        performData = "";
    }

    /**
     * @notice Chainlink Automation 执行快照更新。
     * @dev 如果 automationForwarder 不为 address(0)，则只允许 forwarder 或 owner 调用。
     * @param performData Chainlink 传入的执行数据，本合约未使用。
     */
    function performUpkeep(bytes calldata performData) external override {
        (performData);

        address forwarder = automationForwarder;

        if (
            forwarder != address(0) &&
            msg.sender != forwarder &&
            msg.sender != owner()
        ) {
            revert UnauthorizedUpkeepCaller(msg.sender);
        }

        if (!_upkeepNeeded()) {
            revert UpkeepNotNeeded(lastUpdateTime, block.timestamp);
        }

        lastUpdateTime = block.timestamp;

        _createHashPowerSnapshot();
    }

    // ============ User Functions ============

    /**
     * @notice 开始挖矿。
     * @dev 用户必须先调用 startMint()，再通过 ERC1363 的 transferAndCall 或 approveAndCall 质押。
     *      如果未 startMint 就质押，ERC1363 回调会 revert，token 转账也会整体回滚。
     */
    function startMint() external nonReentrant whenNotPaused {
        address user = msg.sender;
        Minter storage m = minter[user];

        if (m.isStartMint) {
            revert MiningAlreadyStarted(user);
        }

        uint48 nowTs = _currentTimestamp();

        m.isStartMint = true;
        m.startMintTime = nowTs;
        m.lastMintTime = nowTs;
        m.lastClaimTime = nowTs;

        _registerMiner(user);

        emit StartMint(user, true, nowTs, nowTs);
    }

    /**
     * @notice 领取 GBC 奖励。
     * @dev 合约暂停时禁止领取奖励。
     */
    function withdrawRewards() external nonReentrant whenNotPaused {
        _claimRewards(msg.sender);
    }

    /**
     * @notice 赎回质押 USDT。
     * @dev 故意不加 whenNotPaused：
     *      - pause 后禁止新质押和领取奖励；
     *      - 但仍允许用户赎回本金，避免管理员暂停后锁死用户资产。
     *
     *      即使 GBC 奖励池不足，用户也可以赎回本金。
     *
     * @param amount 赎回的 USDT 数量。
     */
    function withdrawStakeUsdt(uint256 amount) external nonReentrant {
        address user = msg.sender;
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        if (amount == 0 || amount > m.totalUsdt) {
            revert InvalidWithdrawAmount(amount);
        }

        if (amount != m.totalUsdt && amount % STAKE_UNIT != 0) {
            revert InvalidWithdrawAmount(amount);
        }

        _accrueRewards(user);

        uint256 beforePower = getPower(user);
        bool wasActive = _isActiveStake(m.totalUsdt);

        m.totalUsdt -= amount;
        totalStakedUsdt -= amount;

        uint256 afterPower = getPower(user);
        bool isActive = _isActiveStake(m.totalUsdt);

        /**
         * 用户全额赎回时，清除奖励余数。
         *
         * 这是全额赎回场景下的主清零点：
         * - 已进入 accruedRewards 的完整最小单位奖励不会丢失；
         * - 这里只舍弃不足 1 个 GBC 最小单位的奖励零头；
         * - _accrueRewards() 里 power == 0 的清零分支是兜底逻辑，
         *   用于处理领取奖励等非赎回路径下的无算力状态。
         */
        if (!isActive) {
            m.rewardRemainder = 0;
        }

        _replaceTotalPower(beforePower, afterPower);
        _syncActiveMinerCount(wasActive, isActive);

        uint256 balance = USDT.balanceOf(address(this));

        if (balance < amount) {
            revert InsufficientUSDT(amount, balance);
        }

        USDT.safeTransfer(user, amount);

        emit WithdrawStake(user, amount);
    }

    // ============ Reward Funding ============

    /**
     * @notice 向合约补充 GBC 奖励池。
     * @dev GBC 不要求支持 ERC1363，普通 ERC20 approve + fundRewards 即可。
     *      本合约不接受 fee-on-transfer / deflationary GBC；
     *      实际到账数量必须等于 amount。
     *
     * @param amount 充值的 GBC 数量。
     */
    function fundRewards(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert InvalidAmount(amount);
        }

        uint256 beforeBalance = GBC.balanceOf(address(this));

        GBC.safeTransferFrom(msg.sender, address(this), amount);

        uint256 afterBalance = GBC.balanceOf(address(this));
        uint256 received = afterBalance - beforeBalance;

        if (received != amount) {
            revert TransferAmountMismatch(amount, received);
        }

        emit RewardsFunded(msg.sender, received);
    }

    // ============ View Functions ============

    /**
     * @notice 获取用户当前算力。
     * @dev 未 startMint 或未有效质押时，算力为 0。
     * @param user 用户地址。
     * @return power 用户当前算力。
     */
    function getPower(address user) public view returns (uint256 power) {
        Minter storage m = minter[user];

        if (!m.isStartMint) {
            return 0;
        }

        return _powerForStake(m.totalUsdt);
    }

    /**
     * @notice 查询用户待领取奖励。
     * @dev 返回值 reward 的单位是 GBC 最小单位。
     *
     *      如果 power == 0，仍然会返回 m.accruedRewards。
     *      这是因为 accruedRewards 是之前已经完整记账的奖励，
     *      即使用户之后全额赎回本金，也不应被清除。
     *
     * @param user 用户地址。
     * @return reward 待领取奖励，单位是 GBC 最小单位。
     * @return power 用户当前算力。
     */
    function pendingRewards(
        address user
    ) public view returns (uint256 reward, uint256 power) {
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            return (0, 0);
        }

        power = getPower(user);
        reward = m.accruedRewards;

        if (power == 0) {
            return (reward, power);
        }

        if (block.timestamp > uint256(m.lastMintTime)) {
            uint256 elapsed = block.timestamp - uint256(m.lastMintTime);

            (uint256 rewardDelta, ) = _computeRewardDelta(
                power,
                elapsed,
                m.rewardRemainder
            );

            reward += rewardDelta;
        }
    }

    /**
     * @notice 查询用户奖励是否达到领取条件。
     * @param user 用户地址。
     * @return reward 待领取奖励，单位是 GBC 最小单位。
     * @return power 用户当前算力。
     * @return claimable 当前是否可领取。
     * @return nextClaimTime 下一次最早可领取时间。
     */
    function claimableRewards(
        address user
    )
        external
        view
        returns (
            uint256 reward,
            uint256 power,
            bool claimable,
            uint256 nextClaimTime
        )
    {
        Minter storage m = minter[user];

        (reward, power) = pendingRewards(user);

        if (!m.isStartMint || m.startMintTime == 0) {
            return (0, 0, false, 0);
        }

        nextClaimTime = uint256(m.lastClaimTime) + TIMEINTERVAL;
        claimable = block.timestamp >= nextClaimTime && reward > 0;
    }

    /**
     * @notice 聚合查询用户矿工信息。
     * @dev 建议前端优先使用本函数，而不是 public mapping 自动生成的 minter(address) getter。
     *
     * @param user 用户地址。
     * @return isStartMint 是否已开始挖矿。
     * @return startMintTime 开始挖矿时间。
     * @return lastMintTime 上次奖励记账时间。
     * @return lastClaimTime 上次成功领取奖励时间。
     * @return totalUsdt 用户质押总额。
     * @return accruedRewards 已完整记账但尚未领取的奖励。
     * @return rewardRemainder 奖励计算余数，始终小于 1 hours。
     * @return power 当前算力。
     * @return pendingReward 当前待领取奖励。
     * @return claimable 当前是否可领取。
     * @return nextClaimTime 下一次最早可领取时间。
     */
    function getMinter(
        address user
    )
        external
        view
        returns (
            bool isStartMint,
            uint256 startMintTime,
            uint256 lastMintTime,
            uint256 lastClaimTime,
            uint256 totalUsdt,
            uint256 accruedRewards,
            uint256 rewardRemainder,
            uint256 power,
            uint256 pendingReward,
            bool claimable,
            uint256 nextClaimTime
        )
    {
        Minter storage m = minter[user];

        isStartMint = m.isStartMint;
        startMintTime = uint256(m.startMintTime);
        lastMintTime = uint256(m.lastMintTime);
        lastClaimTime = uint256(m.lastClaimTime);
        totalUsdt = m.totalUsdt;
        accruedRewards = m.accruedRewards;
        rewardRemainder = uint256(m.rewardRemainder);

        (pendingReward, power) = pendingRewards(user);

        if (!m.isStartMint || m.startMintTime == 0) {
            claimable = false;
            nextClaimTime = 0;
        } else {
            nextClaimTime = uint256(m.lastClaimTime) + TIMEINTERVAL;
            claimable = block.timestamp >= nextClaimTime && pendingReward > 0;
        }
    }

    /**
     * @notice 查询 USDT 本金池会计状态，用于运营监控。
     * @dev 正常情况下 shortfall 应为 0。
     *      surplus > 0 表示存在误转或额外 USDT，可由 owner 通过 rescueStakeTokenSurplus() 清理。
     *
     * @return balance 合约当前 USDT 余额。
     * @return accountedStake 合约记录的用户质押本金总额。
     * @return surplus 超额 USDT 余额。
     * @return shortfall 本金池缺口。
     */
    function getStakeTokenAccounting()
        external
        view
        returns (
            uint256 balance,
            uint256 accountedStake,
            uint256 surplus,
            uint256 shortfall
        )
    {
        balance = USDT.balanceOf(address(this));
        accountedStake = totalStakedUsdt;

        if (balance >= accountedStake) {
            surplus = balance - accountedStake;
            shortfall = 0;
        } else {
            surplus = 0;
            shortfall = accountedStake - balance;
        }
    }

    /**
     * @notice 查询当前保存的快照数量。
     * @return length 当前快照数量。
     */
    function getHashPowerHistoryLength() external view returns (uint256 length) {
        return hashPowerHistoryLength;
    }

    /**
     * @notice 查询指定下标的快照。
     * @param index 快照逻辑下标，0 表示当前保存的最老快照。
     * @return timestamp 快照时间。
     * @return _totalHashPower 快照时总算力。
     * @return _totalStakedUsdt 快照时总质押 USDT。
     * @return totalMiners 快照时活跃矿工数量。
     * @return blockNumber 快照所在区块号。
     */
    function getHashPowerSnapshot(
        uint256 index
    )
        external
        view
        returns (
            uint256 timestamp,
            uint256 _totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        )
    {
        HashPowerSnapshot memory s = _hashPowerHistory[
            _historyPhysicalIndex(index)
        ];

        return (
            s.timestamp,
            s.totalHashPower,
            s.totalStakedUsdt,
            s.totalMiners,
            s.blockNumber
        );
    }

    /**
     * @notice 查询最新快照。
     * @return timestamp 快照时间。
     * @return _totalHashPower 快照时总算力。
     * @return _totalStakedUsdt 快照时总质押 USDT。
     * @return totalMiners 快照时活跃矿工数量。
     * @return blockNumber 快照所在区块号。
     */
    function getLatestHashPowerSnapshot()
        external
        view
        returns (
            uint256 timestamp,
            uint256 _totalHashPower,
            uint256 _totalStakedUsdt,
            uint256 totalMiners,
            uint256 blockNumber
        )
    {
        uint256 len = hashPowerHistoryLength;

        if (len == 0) {
            revert NoSnapshots();
        }

        HashPowerSnapshot memory s = _hashPowerHistory[
            _historyPhysicalIndex(len - 1)
        ];

        return (
            s.timestamp,
            s.totalHashPower,
            s.totalStakedUsdt,
            s.totalMiners,
            s.blockNumber
        );
    }

    /**
     * @notice 查询最近 count 条快照。
     * @param count 需要查询的快照数量。
     * @return result 最近的快照数组。
     */
    function getRecentHashPowerSnapshots(
        uint256 count
    ) external view returns (HashPowerSnapshot[] memory result) {
        if (count == 0) {
            revert CountMustBePositive();
        }

        uint256 len = hashPowerHistoryLength;
        uint256 n = count > len ? len : count;

        result = new HashPowerSnapshot[](n);

        uint256 start = len - n;

        for (uint256 i = 0; i < n; i++) {
            result[i] = _hashPowerHistory[_historyPhysicalIndex(start + i)];
        }
    }

    /**
     * @notice 查询当前总算力。
     * @return currentTotalHashPower 当前总算力。
     */
    function getCurrentTotalHashPower()
        external
        view
        returns (uint256 currentTotalHashPower)
    {
        return totalHashPower;
    }

    /**
     * @notice 查询历史注册矿工总数。
     * @return totalMiners 历史注册矿工总数。
     */
    function getTotalMiners() external view returns (uint256 totalMiners) {
        return minerAddresses.length;
    }

    /**
     * @notice 查询当前活跃矿工数量。
     * @return activeMiners 当前有有效质押的矿工数量。
     */
    function getActiveMiners() external view returns (uint256 activeMiners) {
        return totalActiveMiners;
    }

    // ============ Owner Functions ============

    /**
     * @notice 暂停合约。
     * @dev 暂停后禁止 startMint、质押、领取奖励，但仍允许赎回本金。
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice 解除暂停。
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice owner 手动更新总算力快照，并重置 Chainlink Automation 节奏。
     * @dev 本函数会更新 lastUpdateTime，因此下一次 Automation 触发时间会顺延。
     */
    function manualUpdateHashPower() external onlyOwner {
        lastUpdateTime = block.timestamp;

        _createHashPowerSnapshot();
    }

    /**
     * @notice owner 手动创建总算力快照，但不重置 Chainlink Automation 节奏。
     * @dev 适合调试、补采样或临时记录，不影响 lastUpdateTime。
     */
    function manualCreateHashPowerSnapshot() external onlyOwner {
        _createHashPowerSnapshot();
    }

    /**
     * @notice 设置 Chainlink Automation Forwarder。
     * @dev Custom Logic Upkeep 注册完成后才能知道 forwarder 地址。
     *      传 address(0) 表示关闭限制，performUpkeep 重新允许任何人调用。
     *
     * @param newForwarder 新的 Chainlink Automation Forwarder 地址。
     */
    function setAutomationForwarder(address newForwarder) external onlyOwner {
        address oldForwarder = automationForwarder;
        automationForwarder = newForwarder;

        emit AutomationForwarderUpdated(oldForwarder, newForwarder);
    }

    /**
     * @notice 救援非 USDT / 非 GBC 的误转 token。
     * @dev 保护 USDT 本金池和 GBC 奖励池，避免 owner 直接挪走用户资产或奖励池。
     *
     * @param token 被救援 token 地址。
     * @param to 接收地址。
     * @param amount 救援数量。
     */
    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (token == address(0) || token.code.length == 0) {
            revert InvalidTokenAddress(token);
        }

        if (to == address(0)) {
            revert ZeroAddress();
        }

        if (amount == 0) {
            revert InvalidAmount(amount);
        }

        if (token == address(USDT) || token == address(GBC)) {
            revert ProtectedToken(token);
        }

        IERC20(token).safeTransfer(to, amount);

        emit TokenRescued(token, to, amount);
    }

    /**
     * @notice 只允许提走 USDT 超额余额，不能提走用户质押本金。
     * @dev 超额余额通常来自误转或测试补偿。
     *
     * @param to 接收地址。
     * @param amount 救援的 USDT 超额余额数量。
     */
    function rescueStakeTokenSurplus(
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        if (amount == 0) {
            revert InvalidAmount(amount);
        }

        uint256 balance = USDT.balanceOf(address(this));

        uint256 surplus = balance > totalStakedUsdt
            ? balance - totalStakedUsdt
            : 0;

        if (amount > surplus) {
            revert RescueAmountTooLarge(amount, surplus);
        }

        USDT.safeTransfer(to, amount);

        emit TokenRescued(address(USDT), to, amount);
    }

    // ============ Internal Accounting ============

    function _stakeAccounting(address user, uint256 amount) internal {
        _validateStake(user, amount);

        _accrueRewards(user);

        Minter storage m = minter[user];

        uint256 beforePower = getPower(user);
        bool wasActive = _isActiveStake(m.totalUsdt);

        m.totalUsdt += amount;
        totalStakedUsdt += amount;

        uint256 afterPower = getPower(user);
        bool isActive = _isActiveStake(m.totalUsdt);

        _replaceTotalPower(beforePower, afterPower);
        _syncActiveMinerCount(wasActive, isActive);

        emit Staked(user, amount, m.totalUsdt);
    }

    function _validateStake(address user, uint256 amount) internal view {
        if (user == address(0)) {
            revert ZeroAddress();
        }

        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        if (amount == 0 || amount % STAKE_UNIT != 0) {
            revert InvalidStakeAmount(amount);
        }
    }

    function _claimRewards(address user) internal {
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        uint256 nextClaimTime = uint256(m.lastClaimTime) + TIMEINTERVAL;

        if (block.timestamp < nextClaimTime) {
            revert ClaimTooSoon(nextClaimTime);
        }

        _accrueRewards(user);

        uint256 reward = m.accruedRewards;

        if (reward == 0) {
            revert NoRewards();
        }

        uint256 gbcBalance = GBC.balanceOf(address(this));

        if (gbcBalance < reward) {
            revert InsufficientGBC(reward, gbcBalance);
        }

        m.accruedRewards = 0;
        m.lastClaimTime = _currentTimestamp();

        GBC.safeTransfer(user, reward);

        emit WithdrawRewards(user, reward);
    }

    function _accrueRewards(address user) internal {
        Minter storage m = minter[user];

        if (!m.isStartMint || m.startMintTime == 0) {
            revert MiningNotStarted(user);
        }

        uint48 nowTs = _currentTimestamp();
        uint256 elapsed = uint256(nowTs) - uint256(m.lastMintTime);

        if (elapsed == 0) {
            return;
        }

        uint256 power = getPower(user);

        if (power > 0) {
            (
                uint256 rewardDelta,
                uint32 newRemainder
            ) = _computeRewardDelta(power, elapsed, m.rewardRemainder);

            m.accruedRewards += rewardDelta;
            m.rewardRemainder = newRemainder;
        } else {
            /**
             * 无有效算力时不继续保留奖励余数。
             *
             * 这是兜底清零点：
             * - 全额赎回时，withdrawStakeUsdt() 已经会主动清零；
             * - 这里用于处理用户已无质押后再次触发奖励记账的情况；
             * - 已经完整记账的 accruedRewards 不受影响。
             */
            m.rewardRemainder = 0;
        }

        m.lastMintTime = nowTs;
    }

    /**
     * @notice 计算本周期奖励增量和新的奖励余数。
     * @dev rewardDelta = power * elapsed / 1 hours。
     *
     *      使用 Math.mulDiv 防止 power * elapsed 直接乘法溢出。
     *      使用 mulmod 获取除以 1 hours 后的余数。
     *
     *      语义说明：
     *      - 本函数只做纯计算，不负责决定是否丢弃历史余数；
     *      - 当 power == 0 时，不产生新增奖励，但返回 previousRemainder；
     *      - 调用方如果希望在无算力时丢弃余数，应在外层显式清零。
     *
     *      上界说明：
     *      - previousRemainder 按不变量始终 < 1 hours；
     *      - extraRemainder = mulmod(..., 1 hours)，因此也始终 < 1 hours；
     *      - combinedRemainder 最大 < 2 hours，也就是 < 7200；
     *      - 因此 previousRemainder + extraRemainder 不存在 uint256 溢出风险。
     *
     * @param power 用户当前算力。
     * @param elapsed 距离上次记账的秒数。
     * @param previousRemainder 上次保存的奖励余数。
     * @return rewardDelta 本周期新增的完整奖励。
     * @return newRemainder 新的奖励余数。
     */
    function _computeRewardDelta(
        uint256 power,
        uint256 elapsed,
        uint32 previousRemainder
    ) internal pure returns (uint256 rewardDelta, uint32 newRemainder) {
        if (power == 0) {
            return (0, previousRemainder);
        }

        if (elapsed == 0) {
            return (0, previousRemainder);
        }

        uint256 extraReward = Math.mulDiv(power, elapsed, 1 hours);
        uint256 extraRemainder = mulmod(power, elapsed, 1 hours);

        uint256 combinedRemainder = uint256(previousRemainder) + extraRemainder;

        rewardDelta = extraReward + (combinedRemainder / 1 hours);
        newRemainder = (combinedRemainder % 1 hours).toUint32();
    }

    function _registerMiner(address minerAddr) internal {
        if (!isMinerRegistered[minerAddr]) {
            minerAddresses.push(minerAddr);
            isMinerRegistered[minerAddr] = true;
        }
    }

    /**
     * @dev 读取 STAKE_UNIT、HASHRATE、BASICCOMPUTINGPOWER 这些 immutable 配置，
     *      因此保留 view，而不是 pure。
     */
    function _powerForStake(uint256 stakeAmount) internal view returns (uint256) {
        uint256 units = stakeAmount / STAKE_UNIT;

        if (units == 0) {
            return 0;
        }

        return BASICCOMPUTINGPOWER + units * HASHRATE;
    }

    /**
     * @dev 读取 STAKE_UNIT 这个 immutable 配置，因此保留 view，而不是 pure。
     */
    function _isActiveStake(uint256 stakeAmount) internal view returns (bool) {
        return stakeAmount / STAKE_UNIT > 0;
    }

    function _replaceTotalPower(
        uint256 beforePower,
        uint256 afterPower
    ) internal {
        if (afterPower >= beforePower) {
            totalHashPower += afterPower - beforePower;
        } else {
            totalHashPower -= beforePower - afterPower;
        }
    }

    function _syncActiveMinerCount(bool wasActive, bool isActive) internal {
        if (!wasActive && isActive) {
            totalActiveMiners += 1;
        } else if (wasActive && !isActive) {
            if (totalActiveMiners == 0) {
                revert ActiveMinerCounterUnderflow();
            }

            totalActiveMiners -= 1;
        }
    }

    function _createHashPowerSnapshot() internal {
        HashPowerSnapshot memory snapshot = HashPowerSnapshot({
            timestamp: block.timestamp,
            totalHashPower: totalHashPower,
            totalStakedUsdt: totalStakedUsdt,
            totalMiners: totalActiveMiners,
            blockNumber: block.number
        });

        uint256 writeIndex = _nextSnapshotIndex;

        _hashPowerHistory[writeIndex] = snapshot;
        _nextSnapshotIndex = (writeIndex + 1) % MAX_HISTORY_LENGTH;

        if (hashPowerHistoryLength < MAX_HISTORY_LENGTH) {
            hashPowerHistoryLength += 1;
        }

        emit HashPowerUpdated(
            snapshotCounter,
            snapshot.timestamp,
            snapshot.totalHashPower,
            snapshot.totalStakedUsdt,
            snapshot.totalMiners
        );

        unchecked {
            snapshotCounter += 1;
        }
    }

    function _historyPhysicalIndex(
        uint256 index
    ) internal view returns (uint256) {
        uint256 len = hashPowerHistoryLength;

        if (index >= len) {
            revert IndexOutOfBounds(index, len);
        }

        if (len < MAX_HISTORY_LENGTH) {
            return index;
        }

        return (_nextSnapshotIndex + index) % MAX_HISTORY_LENGTH;
    }

    function _upkeepNeeded() internal view returns (bool) {
        return block.timestamp >= lastUpdateTime + UPDATE_INTERVAL;
    }

    /**
     * @dev 将当前区块时间戳压缩为 uint48。
     *      uint48 的秒级时间戳范围约为 890 万年，远超合约预期生命周期。
     *      这里使用 SafeCast，若异常链环境给出超范围时间戳会直接 revert。
     */
    function _currentTimestamp() internal view returns (uint48) {
        return block.timestamp.toUint48();
    }
}
