// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

library Counters {
    struct Counter {
        uint256 _value;
    }

    function current(Counter storage counter) internal view returns (uint256) {
        return counter._value;
    }

    function increment(Counter storage counter) internal {
        unchecked {
            counter._value += 1;
        }
    }
}

/**
 * @title 服务器节点管理合约
 * @notice 管理节点创建、分配节点、奖励分发、暂停节点、白名单、多签等所有功能
 * @dev 可升级，确保安全可靠
 */
contract ServerNodeV2Backup is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ====== 基本配置 ======
    uint16 public constant BIGNODE = 2000; // 最多2000个物理节点
    uint16 public constant BASENODE = 500; // 基础节点数，用来算奖励
    uint8 public constant MAX_WHITELIST = 3; // 白名单最多3个人
    uint256 public constant DEFAULT_CAPACITY = 1_000_000; // 每个节点100万容量
    // SCALE 与 DEFAULT_CAPACITY 强绑定，避免后续仅改一处导致等效值计算偏差
    uint256 private constant SCALE = DEFAULT_CAPACITY; // 精度放大倍数，用来算等效值

    // 常量定义
    uint256 public constant MAX_BATCH_ALLOCATIONS = 20; // 批量分配最大数量
    uint256 public constant MAX_REWARD_USERS = 20; // 奖励分发最大用户数
    uint256 public constant MAX_USER_ALLOCATIONS = 100; // 单个用户最大分配记录数
    uint256 public constant MAX_STAKE_ADDRESSES = 50; // 单个用户最大质押地址数
    uint256 public constant MAX_BATCH_NODE_CREATE = 50; // 单次批量创建节点最大数量，防止 O(n²) Gas DoS
    uint256 public constant MEDIUM_NODE_AMOUNT = 200_000; // 中节点金额
    uint256 public constant SMALL_NODE_AMOUNT = 50_000; // 小节点金额
    uint256 public constant MAX_DAILY_REWARD = 100 ether; // 每日奖励上限
    uint256 public constant MAX_CLEANUP_STEPS = 500; // 清理过期提案最大步数
    uint256 public constant MIN_STAKE_DURATION = 12 hours; // ✅ 最小质押时间，防止 Reward Timing Attack

    // ====== 核心数据 ======
    using Counters for Counters.Counter;
    Counters.Counter private _counter; // 用来生成节点ID的计数器

    address private REWARD; // 奖励计算器的地址
    uint256 public totalPhysicalNodesEquivalent; // 所有人总共买了多少节点的等效值
    uint256 public totalActiveEquivalent; // ✅ Critical: 全局活跃等效值，用于奖励计算分母
    uint256 public lastRewardActiveEquivalent; // ✅ Bug 2 修复: 上一次奖励时的活跃等效值快照
    // ✅ 修复问题Y：独立布尔标志，防止 lastRewardActiveEquivalent 降至 0 后哨兵被"重置"
    bool public hasDistributedReward;
    NodeInfo[] public deployNode; // 所有已创建的节点

    mapping(address => uint256) public userPhysicalNodesEquivalent; // 每个人买了多少节点的等效值
    mapping(address => mapping(uint16 => uint256)) public lastRewardDay; // 每个人每年最后领奖励是哪天

    // ====== 节点信息结构 ======
    struct NodeInfo {
        string ip; // IP地址
        string name; // 节点名称
        bool isActive; // 是否激活
        address nodeStakeAddress; // 节点质押地址
        uint256 id; // 节点ID
        uint256 createTime; // 创建时间
    }

    // 组合分配的结构：中节点+小节点+商品
    struct NodeCombination {
        uint8 mediumNodes; // 中节点数量（每个20万）
        uint8 smallNodes; // 小节点数量（每个5万）
        uint256 commodity; // 商品金额（1-100万之间）
    }

    // 分配记录的结构：每次分配记下来
    struct AllocationRecord {
        uint256 timestamp; // 分配时间
        address user; // 用户地址
        address stakeAddress; // 质押地址
        uint8 nodeType; // 节点类型（1=大节点，2=中节点，3=小节点，4=商品）
        uint256 amount; // 分配金额
        uint256 nodeId; // 关联的节点ID
        uint256 nonce; // 唯一标识符，防止同一区块内相同参数记录误匹配
    }

    // 批量分配的结构
    struct Allocation {
        address user; // 用户地址
        address stakeAddress; // 质押地址
        uint8 nodeType; // 节点类型
        uint256 quantity; // 数量（用于大/中/小节点）
        uint256 amount; // 金额（用于商品）
    }

    // 用户质押缓存结构（用于奖励分发优化）
    struct UserStakeCache {
        address[] stakeAddresses;
        uint256[] equivalents;
        uint256 totalEquivalent;
    }

    // ====== 各种映射和数组 ======
    mapping(address => bool) public whiteList; // 白名单
    uint8 public currentWhitelistCount; // 当前白名单人数

    mapping(uint256 => uint256) public nodeTotalAllocated; // 每个节点总共分配了多少金额（关键）
    mapping(uint256 => bool) public isNodeAllocatedAsBig; // 节点是否被分配成大节点了

    // 防止 currentDay 倒退导致重复领取
    uint256 public lastGlobalRewardDay;

    // ✅ 修复问题AC：当天 dailyReward 快照，确保同一天多批次调用使用相同值
    uint256 public lastDailyRewardSnapshot;

    // ✅ 上一次奖励的时间戳，用于防止 Reward Timing Attack
    // 分配必须在上一次奖励之前就已存在，才能参与本次奖励
    uint256 public lastRewardTimestamp;

    // ✅ 用户最后一次分配变化的时间戳，用于防止 Allocation State Manipulation Attack
    // 用户必须在奖励前 MIN_STAKE_DURATION 内没有改变分配状态
    mapping(address => uint256) public lastAllocationChangeTimestamp;

    // 分配记录 nonce 计数器，用于唯一标识每条记录
    uint256 private _allocationNonce;

    mapping(address => AllocationRecord[]) public userAllocationRecords; // 每个人的分配记录
    mapping(uint256 => AllocationRecord[]) public nodeAllocationRecords; // 每个节点的分配记录

    mapping(string => uint256) public nodeIdByIP; // 通过IP查节点ID
    mapping(uint256 => uint256) public nodeIndexById; // 通过节点ID查索引

    // ====== 多签相关 ======
    uint256 public withdrawThreshold; // 多签阈值
    address[] public withdrawSigners; // 多签用户列表
    mapping(address => bool) public isWithdrawSigner; // 是否是签名用户
    uint256 public nextWithdrawProposalId; // 下一个提款提案ID
    struct WithdrawProposal {
        uint256 amount;
        address to;
        uint256 createdAt;
        uint256 confirmations;
        bool executed;
        address proposer;
    }
    mapping(uint256 => WithdrawProposal) public withdrawProposals; // 提款提案
    mapping(uint256 => mapping(address => bool)) public withdrawalConfirmations; // 提款确认
    mapping(uint256 => bool) public withdrawProposalFinalized; // 提案是否已完成结算（执行/过期）
    mapping(address => uint256) public signerActiveProposalCount; // 每个签名者当前活跃提案数（创建维度）

    uint256 public activeWithdrawProposalCount; // 当前活跃提案总数
    uint256 public withdrawProposalCleanupCursor; // 过期清理游标（增量扫描）
    uint256 public constant PROPOSAL_EXPIRY_TIME = 7 days; // ✅ 提案过期时间
    uint256 public constant MAX_ACTIVE_WITHDRAW_PROPOSALS = 200; // 活跃提案总量上限
    uint256 public constant MAX_SIGNER_ACTIVE_WITHDRAW_PROPOSALS = 20; // 单签名者活跃提案上限
    uint256 public constant EXPIRED_PROPOSAL_CLEANUP_STEPS = 120; // 单次过期清理扫描步数

    // ====== 控制开关 ======
    bool public pausedNodeAllocation; // 节点分配是否暂停
    bool public pausedNodeAllocationReward; // 节点分配奖励是否暂停

    // ====== 事件 ======
    event CreateNodeInfo(
        string indexed ip,
        string name,
        bool isActive,
        address indexed nodeStakeAddress,
        uint256 indexed id,
        uint256 capacity
    );
    event NodeStatusChanged(uint256 indexed nodeId, bool paused);
    event AllocationStatusChanged(
        address indexed admin,
        bool paused,
        bool isRewardPaused
    );
    event WhitelistUpdated(address indexed user, bool added);
    event CombinedNodesAllocated(
        address indexed user,
        address indexed stakeAddress,
        uint8 mediumNodes,
        uint8 smallNodes,
        uint256 commodity
    );
    event NodeAllocated(
        address indexed user,
        address indexed stakeAddress,
        uint8 nodeType,
        uint256 amount,
        uint256 indexed nodeId
    );
    event NodeDeallocated(
        address indexed user,
        address indexed stakeAddress,
        uint8 nodeType,
        uint256 amount,
        uint256 indexed nodeId
    );
    event StakeRewardDistributed(
        address indexed user,
        address indexed stakeAddress,
        uint256 amount,
        uint16 year
    );
    event RewardDistributed(address indexed user, uint256 amount, uint16 year);
    event BatchRewardsDistributed(
        uint256 count,
        uint256 totalAmount,
        uint16 year
    );
    event RewardStatusChanged(address indexed admin, bool paused);
    event WithdrawSignerAdded(address indexed signer);
    event WithdrawSignerRemoved(address indexed signer);
    event WithdrawProposalCreated(
        uint256 indexed proposalId,
        uint256 amount,
        address to
    );
    event WithdrawProposalConfirmed(
        uint256 indexed proposalId,
        address indexed signer
    );
    event WithdrawProposalExecuted(
        uint256 indexed proposalId,
        uint256 amount,
        address to
    );
    event WithdrawProposalExpired(uint256 indexed proposalId);
    event RewardUserSkipped(address indexed user, uint8 reason);
    event WithdrawMultiSigInitialized(address[] signers, uint256 threshold);
    event WithdrawThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event RewardCalculatorUpdated(
        address indexed oldCalculator,
        address indexed newCalculator
    );

    // 只有管理员或白名单才能分配节点
    modifier onlyAllocationAuthorized() {
        require(
            msg.sender == owner() || whiteList[msg.sender],
            "Only owner or whitelist"
        );
        _;
    }

    // 节点分配没暂停时才能调用
    modifier whenAllocationNotPaused() {
        require(!pausedNodeAllocation, "Allocation paused");
        _;
    }

    // 节点分配奖励没暂停时才能调用
    modifier whenNodeAllocationRewardNotPaused() {
        require(
            !pausedNodeAllocationReward,
            "Node allocation reward is paused"
        );
        _;
    }

    // 只有多签用户才能调用
    modifier onlyWithdrawMultiSig() {
        require(isWithdrawSigner[msg.sender], "Not signer");
        _;
    }

    error InvalidUser();
    error InvalidStake();
    error InvalidNodeId();
    error IndexOutOfBounds();
    error RecordNotFound();
    error RewardCallFailed();
    error InvalidData();
    error AllocationRecordsLimitReached();
    error NodeAllocationExceedsLimit();
    error InsufficientAllocatedAmountToDeallocate();
    error NoNodeSufficientCapacityForCombinedAllocation();
    error NodeIndexCorrupted(
        uint256 nodeId,
        uint256 expectedIndex,
        uint256 actualIndex
    );
    error CommodityMustDeallocateByIndex(); // 商品类型因可能跨节点拆分，必须通过 deallocateNodesByUserRecordIndex 按索引逐条撤销
    error SignerHasPendingConfirmations(); // 签名者有未执行的已确认提案
    error CannotRemoveSignerBelowThreshold(); // 无法移除签名者：低于阈值
    error SignerNotFoundInArray(); // 签名者不在数组中
    error InvalidSignerAddress(); // 无效的签名者地址
    error SignerAlreadyExists(); // 签名者已存在
    error ThresholdExceedsSigners(); // 阈值超过签名者数量
    error ThresholdMustBeGreaterThanOne(); // 阈值必须大于1
    error DuplicateProposalExists(); // 存在相同参数的未执行提案
    error TooManyActiveWithdrawProposals(); // 活跃提案总数超限
    error SignerActiveProposalLimitExceeded(); // 签名者活跃提案数超限
    // ✅ 问题AG：此错误定义已不再使用（问题AA修复后改为返回标志）
    // 保留用于向后兼容，防止升级时存储布局变化
    error StakeAddressLimitExceeded(); // 质押地址数量超限（已废弃）

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev 初始化
     * @param _owner 管理员
     * @param _rewardCalculator 奖励计算器地址
     * @param _withdrawSigners 多签用户列表
     * @param _withdrawThreshold 多签阈值
     */
    function initialize(
        address _owner,
        address _rewardCalculator,
        address[] calldata _withdrawSigners,
        uint256 _withdrawThreshold
    ) public initializer {
        require(_owner != address(0), "Zero owner");
        require(
            _rewardCalculator != address(0) &&
                _rewardCalculator.code.length > 0,
            "Invalid reward"
        );

        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        uint256 length = _withdrawSigners.length;
        require(length > 0, "No signers");
        require(_withdrawThreshold > 1, "Threshold > 1");
        require(_withdrawThreshold <= length, "Too high");

        REWARD = _rewardCalculator;

        // ✅ 验证 REWARD 合约接口兼容性
        _validateRewardCalculator(_rewardCalculator);

        // 初始化多签
        for (uint i = 0; i < length; ) {
            require(
                _withdrawSigners[i] != address(0),
                "Invalid signer address"
            );
            require(
                !isWithdrawSigner[_withdrawSigners[i]],
                "Signer already exists"
            );
            withdrawSigners.push(_withdrawSigners[i]);
            isWithdrawSigner[_withdrawSigners[i]] = true;
            emit WithdrawSignerAdded(_withdrawSigners[i]);
            unchecked {
                ++i;
            }
        }

        withdrawThreshold = _withdrawThreshold;
        emit WithdrawMultiSigInitialized(_withdrawSigners, _withdrawThreshold);

        // ✅ 修复问题C：用初始化时间作为首次奖励的锚定时间戳
        // 这样首次奖励时 MIN_STAKE_DURATION 检查就会生效
        // 防止攻击者在部署后立即分配并领取首次奖励
        lastRewardTimestamp = block.timestamp;
    }

    /**
     * @dev 验证奖励计算器合约接口
     * @param _rewardCalculator 奖励计算器地址
     * ✅ 确保合约实现了 getCurrentDailyReward() returns (uint256, uint256)
     */
    function _validateRewardCalculator(
        address _rewardCalculator
    ) internal view {
        
        (bool success, bytes memory data) = _rewardCalculator.staticcall(
            abi.encodeWithSignature("getDaysSinceDeployment()")
        );

        if (!success) revert RewardCallFailed();
        if (data.length < 32) revert InvalidData();

        // 尝试解码返回值
        uint256 currentDay = abi.decode(data, (uint256));

        // 验证返回值的合理性
        require(currentDay > 0, "Invalid currentDay");

        // 尝试调用 getDailyReward(uint256)
        (bool successReward, bytes memory dataReward) = _rewardCalculator
            .staticcall(
                abi.encodeWithSignature("getDailyReward(uint256)", currentDay)
            );
        if (!successReward) revert RewardCallFailed();
        if (dataReward.length < 32) revert InvalidData();
    }

    /**
     * @dev 更新奖励计算器地址（仅 owner）
     * @param _newRewardCalculator 新的奖励计算器地址
     * ✅ 允许在运行时更新 REWARD 地址，并验证新合约兼容性
     */
    function updateRewardCalculator(
        address _newRewardCalculator
    ) external onlyOwner {
        require(
            _newRewardCalculator != address(0),
            "New reward calculator is zero address"
        );
        require(
            _newRewardCalculator.code.length > 0,
            "New reward calculator has no code"
        );

        // 验证新合约接口兼容性
        _validateRewardCalculator(_newRewardCalculator);

        address oldRewardCalculator = REWARD;
        REWARD = _newRewardCalculator;

        emit RewardCalculatorUpdated(oldRewardCalculator, _newRewardCalculator);
    }

    // ==================== 1）节点创建与管理 ====================
    /**
     * @dev 创建新节点
     * @param _nodeInfo 要创建的节点信息数组
     * 功能：1.检查IP是否唯一 2.设置固定容量100万 3.记录节点信息
     */
    function createNode(
        NodeInfo[] calldata _nodeInfo
    ) public onlyOwner nonReentrant {
        uint256 length = _nodeInfo.length;
        require(length > 0, "No nodes");
        // ✅ 修复高危问题1：限制单次批量创建节点数量，防止 Gas DoS
        require(length <= MAX_BATCH_NODE_CREATE, "Batch too large");
        require(
            deployNode.length + length <= BIGNODE,
            "Exceeds max physical nodes (2000)"
        );

        // 检查批次内的 IP 唯一性
        if (length > 1) {
            for (uint256 i = 0; i < length; ) {
                for (uint256 j = i + 1; j < length; ) {
                    require(
                        keccak256(bytes(_nodeInfo[i].ip)) !=
                            keccak256(bytes(_nodeInfo[j].ip)),
                        "Duplicate IP in batch"
                    );
                    unchecked {
                        ++j;
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }

        for (uint256 i = 0; i < length; ) {
            // ✅ 修复低危问题5：检查IP地址是否为空
            require(
                bytes(_nodeInfo[i].ip).length > 0,
                "IP cannot be empty"
            );

            // 1. 检查IP地址是否唯一
            require(
                nodeIdByIP[_nodeInfo[i].ip] == 0,
                "IP address must be unique"
            );

            require(
                _nodeInfo[i].nodeStakeAddress != address(0),
                "Node stake address must be set"
            );

            // 2. 所有节点容量固定为100万

            // 生成新的节点ID
            _counter.increment();
            uint256 newId = _counter.current();

            // 3. 保存节点信息到数组
            deployNode.push(
                NodeInfo({
                    ip: _nodeInfo[i].ip,
                    name: _nodeInfo[i].name,
                    isActive: _nodeInfo[i].isActive,
                    nodeStakeAddress: _nodeInfo[i].nodeStakeAddress,
                    id: newId,
                    createTime: (_nodeInfo[i].createTime == 0 ||
                        _nodeInfo[i].createTime > block.timestamp)
                        ? block.timestamp
                        : _nodeInfo[i].createTime
                })
            );

            // 初始化：这个节点还没分配过任何金额
            nodeTotalAllocated[newId] = 0;

            // 通过IP记录节点ID，方便后续查询
            nodeIdByIP[_nodeInfo[i].ip] = newId;

            // 通过节点ID记录索引，方便后续查询
            nodeIndexById[newId] = deployNode.length - 1;

            // 触发创建节点事件
            emit CreateNodeInfo(
                _nodeInfo[i].ip,
                _nodeInfo[i].name,
                _nodeInfo[i].isActive,
                _nodeInfo[i].nodeStakeAddress,
                newId,
                DEFAULT_CAPACITY
            );

            unchecked {
                ++i;
            }
        }
    }

    // ==================== 2）管理配置用户投资与分配 ====================

    /**
     * @dev 设置白名单（只有管理员能调用）
     * @param user 要设置的用户地址
     * @param _isTrue true=加入白名单，false=移除白名单
     * 限制：白名单最多只能有3个人
     */
    function setWhiteList(address user, bool _isTrue) external onlyOwner {
        require(user != address(0), "No user");

        if (_isTrue) {
            require(currentWhitelistCount < MAX_WHITELIST, "Max list");
            require(!whiteList[user], "Added");
            whiteList[user] = true;
            currentWhitelistCount++;
        } else {
            require(whiteList[user], "Not added");
            whiteList[user] = false;
            currentWhitelistCount--;
        }
        emit WhitelistUpdated(user, _isTrue);
    }

    /**
     * @dev 批量分配节点（一次最多20个）
     * @param allocations 分配信息数组
     * 权限：只有管理员或白名单用户能调用
     */
    function allocateNodesBatch(
        Allocation[] calldata allocations
    ) external onlyAllocationAuthorized whenAllocationNotPaused nonReentrant {
        uint256 length = allocations.length;
        require(
            length > 0 && length <= MAX_BATCH_ALLOCATIONS,
            "Invalid batch size"
        );

        // 逐个处理每个分配请求
        for (uint i = 0; i < length; ) {
            _processAllocation(
                allocations[i].user,
                allocations[i].stakeAddress,
                allocations[i].nodeType,
                allocations[i].quantity,
                allocations[i].amount
            );
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev 取消分配单个节点
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型
     * @param amount 分配金额
     * @param nodeId 节点ID
     * 功能：取消之前的节点分配，从记录中移除并更新节点容量
     */
    function deallocateNodes(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 amount,
        uint256 nodeId
    ) external onlyOwner nonReentrant {
        // 检查参数
        if (user == address(0)) revert InvalidUser();
        if (stakeAddress == address(0)) revert InvalidStake();
        if (nodeId == 0) revert InvalidNodeId();
        require(amount > 0, "Invalid amount");
        // 商品分配（type 4）可能被跨节点拆分为多条部分金额记录，
        // 按 amount 精确匹配无法定位，必须通过 deallocateNodesByUserRecordIndex 按索引逐条撤销
        if (nodeType == 4) revert CommodityMustDeallocateByIndex();

        // 检查节点是否存在
        uint256 index = nodeIndexById[nodeId];
        require(index < deployNode.length, "Node not exist");
        require(deployNode[index].id == nodeId, "Node ID mismatch");

        // 通过用户记录定位并撤销
        AllocationRecord[] storage userRecords = userAllocationRecords[user];
        bool found = false;
        uint256 userRecordsLength = userRecords.length;
        for (uint256 i = 0; i < userRecordsLength; ) {
            AllocationRecord storage record = userRecords[i];
            if (
                record.stakeAddress == stakeAddress &&
                record.nodeType == nodeType &&
                record.amount == amount &&
                record.nodeId == nodeId
            ) {
                AllocationRecord memory recordCopy = record;
                _deallocateUserRecordByIndex(user, i, recordCopy);
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        if (!found) revert RecordNotFound();

        // ✅ 更新用户最后一次分配变化的时间戳
        lastAllocationChangeTimestamp[user] = block.timestamp;

        // 触发取消分配事件
        emit NodeDeallocated(user, stakeAddress, nodeType, amount, nodeId);
    }

    /**
     * @dev 通过用户分配记录索引撤销分配
     * @param user 用户地址
     * @param userRecordIndex 用户分配记录数组下标
     */
    function deallocateNodesByUserRecordIndex(
        address user,
        uint256 userRecordIndex
    ) external onlyOwner nonReentrant {
        if (user == address(0)) revert InvalidUser();
        AllocationRecord[] storage userRecords = userAllocationRecords[user];
        if (userRecordIndex >= userRecords.length) revert IndexOutOfBounds();

        AllocationRecord memory recordCopy = userRecords[userRecordIndex];
        _deallocateUserRecordByIndex(user, userRecordIndex, recordCopy);

        // ✅ 更新用户最后一次分配变化的时间戳
        lastAllocationChangeTimestamp[user] = block.timestamp;

        emit NodeDeallocated(
            user,
            recordCopy.stakeAddress,
            recordCopy.nodeType,
            recordCopy.amount,
            recordCopy.nodeId
        );
    }

    function _deallocateUserRecordByIndex(
        address user,
        uint256 userRecordIndex,
        AllocationRecord memory record
    ) internal {
        // 1) 从用户分配记录中移除
        AllocationRecord[] storage userRecords = userAllocationRecords[user];
        if (userRecordIndex >= userRecords.length) revert IndexOutOfBounds();
        userRecords[userRecordIndex] = userRecords[userRecords.length - 1];
        userRecords.pop();

        // 2) 从节点分配记录中移除
        AllocationRecord[] storage nodeRecords = nodeAllocationRecords[
            record.nodeId
        ];
        bool nodeRecordFound = false;
        uint256 nodeRecordsLength = nodeRecords.length;
        for (uint256 i = 0; i < nodeRecordsLength; ) {
            AllocationRecord storage nr = nodeRecords[i];
            // ✅ 使用 nonce 精确匹配，避免同一区块内相同参数记录误匹配
            if (nr.nonce == record.nonce) {
                nodeRecords[i] = nodeRecords[nodeRecords.length - 1];
                nodeRecords.pop();
                nodeRecordFound = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        if (!nodeRecordFound) revert RecordNotFound();

        // 3) 更新节点累计分配金额
        if (nodeTotalAllocated[record.nodeId] < record.amount) {
            revert InsufficientAllocatedAmountToDeallocate();
        }
        nodeTotalAllocated[record.nodeId] -= record.amount;

        // 如果节点分配金额归零，重置大节点标记
        if (nodeTotalAllocated[record.nodeId] == 0) {
            isNodeAllocatedAsBig[record.nodeId] = false;
        }

        // 4) 回滚等效值
        uint256 equivalent = (record.amount * SCALE) / DEFAULT_CAPACITY;
        require(
            userPhysicalNodesEquivalent[user] >= equivalent,
            "User equivalent underflow"
        );
        require(
            totalPhysicalNodesEquivalent >= equivalent,
            "Total equivalent underflow"
        );
        userPhysicalNodesEquivalent[user] -= equivalent;
        totalPhysicalNodesEquivalent -= equivalent;

        // ✅ Critical: 回滚活跃等效值
        // 检查节点是否活跃，如果是则从 totalActiveEquivalent 中扣除
        uint256 nodeIndex = nodeIndexById[record.nodeId];
        // ✅ 修复问题D：增加 nodeId 校验，确保索引正确
        if (nodeIndex < deployNode.length && deployNode[nodeIndex].id == record.nodeId && deployNode[nodeIndex].isActive) {
            require(totalActiveEquivalent >= equivalent, "Active equivalent underflow");
            totalActiveEquivalent -= equivalent;

            // ✅ 修复问题A：同步更新快照分母
            // 只有当撤销的记录是"快照有效"的（timestamp < lastRewardTimestamp）时才更新快照
            // 这确保了快照值与实际有效分配保持一致
            if (lastRewardTimestamp > 0 && record.timestamp < lastRewardTimestamp) {
                if (lastRewardActiveEquivalent >= equivalent) {
                    lastRewardActiveEquivalent -= equivalent;
                } else {
                    lastRewardActiveEquivalent = 0;
                }
            }
        }
    }

    /**
     * @dev 单次分配节点
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型（1=大节点，2=中节点，3=小节点，4=商品）
     * @param quantity 数量（用于大/中/小节点）
     * @param amount 金额（用于商品）
     */
    function allocateNodes(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 quantity,
        uint256 amount
    ) external onlyAllocationAuthorized whenAllocationNotPaused nonReentrant {
        _processAllocation(user, stakeAddress, nodeType, quantity, amount);
    }

    /**
     * @dev 处理单个分配请求
     * 功能：根据节点类型调用不同的分配函数
     */
    function _processAllocation(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 quantity,
        uint256 amount
    ) internal {
        // 检查基本参数
        require(user != address(0), "No user");
        require(stakeAddress != address(0), "No stake");
        require(user != stakeAddress, "Same addr");
        require(nodeType >= 1 && nodeType <= 4, "Bad type");

        uint256 totalAmount;

        if (nodeType == 4) {
            // 商品分配：金额1-100万，数量必须为0
            require(
                amount >= 1 && amount <= DEFAULT_CAPACITY,
                "Amount must be 1-1,000,000"
            );
            require(quantity == 0, "Quantity = 0");
            _allocateCommodity(user, stakeAddress, amount);
            totalAmount = amount;
        } else {
            // 大/中/小节点：数量必须大于0，金额必须为0
            require(quantity > 0, "Quantity > 0");
            require(amount == 0, "Amount = 0");

            if (nodeType == 1) {
                // 大节点：整机独占100万
                _allocateBigNodes(user, stakeAddress, quantity);
                totalAmount = quantity * DEFAULT_CAPACITY;
            } else if (nodeType == 2) {
                // 中节点：每个20万
                _allocateMediumNodes(user, stakeAddress, quantity);
                totalAmount = quantity * MEDIUM_NODE_AMOUNT;
            } else if (nodeType == 3) {
                // 小节点：每个5万
                _allocateSmallNodes(user, stakeAddress, quantity);
                totalAmount = quantity * SMALL_NODE_AMOUNT;
            }
        }

        // ✅ 更新用户最后一次分配变化的时间戳，用于防止 Allocation State Manipulation Attack
        lastAllocationChangeTimestamp[user] = block.timestamp;

        // 更新等效值（分配时节点必须是活跃的，所以传入 true）
        _updateEquivalentValue(user, totalAmount, true);
    }

    // ==================== 核心分配逻辑 ====================

    /**
     * @dev 分配大节点
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param quantity 要分配几个大节点
     * 条件：1.节点类型必须为1 2.节点未被分配过 3.节点剩余容量为100万
     */
    function _allocateBigNodes(
        address user,
        address stakeAddress,
        uint256 quantity
    ) internal {
        uint256 allocated = 0; // 已分配的数量
        uint256 nodeCount = deployNode.length;

        for (uint i = 0; i < nodeCount && allocated < quantity; ) {
            NodeInfo storage node = deployNode[i];
            uint256 nodeId = node.id;

            // 1️⃣ 防止 nodeId / index 错位
            if (nodeIndexById[nodeId] != i) {
                revert NodeIndexCorrupted(nodeId, nodeIndexById[nodeId], i);
            }
            // 2️⃣ 节点必须处于 active 状态
            if (!node.isActive) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // 检查节点是否符合分配条件
            if (
                !isNodeAllocatedAsBig[nodeId] && nodeTotalAllocated[nodeId] == 0 // 没被分配过大节点并且没分配过任何金额
            ) {
                // 先记录分配（内部校验通过后再标记，避免 revert 时语义混乱）
                _recordAllocation(
                    user,
                    stakeAddress,
                    1,
                    DEFAULT_CAPACITY,
                    nodeId
                );

                // 记录成功后再标记为大节点
                isNodeAllocatedAsBig[nodeId] = true;

                unchecked {
                    ++allocated;
                }
            }

            unchecked {
                ++i;
            }
        }
        require(allocated == quantity, "No big nodes");
    }

    /**
     * @dev 分配中节点
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param quantity 要分配几个中节点
     * 条件：从剩余容量≥20万的节点中分配
     */
    function _allocateMediumNodes(
        address user,
        address stakeAddress,
        uint256 quantity
    ) internal {
        uint256 remaining = quantity; // 还需要分配的数量
        uint256 nodeCount = deployNode.length;

        // 遍历所有节点
        for (uint i = 0; i < nodeCount && remaining > 0; ) {
            uint256 nodeId = deployNode[i].id;

            // 跳过已被分配为大节点的节点
            if (isNodeAllocatedAsBig[nodeId]) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // 跳过非活动节点
            if (nodeIndexById[nodeId] != i) {
                revert NodeIndexCorrupted(nodeId, nodeIndexById[nodeId], i);
            }
            if (!deployNode[i].isActive) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // 计算节点剩余容量
            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 available = DEFAULT_CAPACITY - allocated;

            // 如果节点剩余容量≥20万，可以分配中节点
            if (available >= MEDIUM_NODE_AMOUNT) {
                // 计算这个节点最多能分配几个中节点
                uint256 maxFromThisNode = available / MEDIUM_NODE_AMOUNT;
                // 实际分配数量 = min(还需要分配的数量, 这个节点能分配的最大数量)
                uint256 allocateCount = remaining > maxFromThisNode
                    ? maxFromThisNode
                    : remaining;

                // 为每个中节点创建一条分配记录
                for (uint j = 0; j < allocateCount; ) {
                    _recordAllocation(
                        user,
                        stakeAddress,
                        2,
                        MEDIUM_NODE_AMOUNT,
                        nodeId
                    );
                    unchecked {
                        ++j;
                    }
                }

                remaining -= allocateCount; // 减少还需要分配的数量
            }

            unchecked {
                ++i;
            }
        }
        require(remaining == 0, "No medium");
    }

    /**
     * @dev 分配小节点
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param quantity 要分配几个小节点
     * 条件：从剩余容量≥5万的节点中分配
     */
    function _allocateSmallNodes(
        address user,
        address stakeAddress,
        uint256 quantity
    ) internal {
        uint256 remaining = quantity;
        uint256 nodeCount = deployNode.length;

        for (uint i = 0; i < nodeCount && remaining > 0; ) {
            uint256 nodeId = deployNode[i].id;
            if (isNodeAllocatedAsBig[nodeId]) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // 跳过非活动节点
            if (nodeIndexById[nodeId] != i) {
                revert NodeIndexCorrupted(nodeId, nodeIndexById[nodeId], i);
            }
            if (!deployNode[i].isActive) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 available = DEFAULT_CAPACITY - allocated;

            if (available >= SMALL_NODE_AMOUNT) {
                uint256 maxFromThisNode = available / SMALL_NODE_AMOUNT;
                uint256 allocateCount = remaining > maxFromThisNode
                    ? maxFromThisNode
                    : remaining;

                for (uint j = 0; j < allocateCount; ) {
                    _recordAllocation(
                        user,
                        stakeAddress,
                        3,
                        SMALL_NODE_AMOUNT,
                        nodeId
                    );
                    unchecked {
                        ++j;
                    }
                }

                remaining -= allocateCount;
            }

            unchecked {
                ++i;
            }
        }
        require(remaining == 0, "No small");
    }

    /**
     * @dev 分配商品
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param amount 商品金额（1-100万）
     * 条件：从剩余容量≥投资金额的节点中分配，可以跨多个节点
     */
    function _allocateCommodity(
        address user,
        address stakeAddress,
        uint256 amount
    ) internal {
        uint256 remaining = amount; // 还需要分配的金额
        uint256 nodeCount = deployNode.length;

        for (uint i = 0; i < nodeCount && remaining > 0; ) {
            uint256 nodeId = deployNode[i].id;
            if (isNodeAllocatedAsBig[nodeId]) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // 跳过非活动节点
            if (nodeIndexById[nodeId] != i) {
                revert NodeIndexCorrupted(nodeId, nodeIndexById[nodeId], i);
            }
            if (!deployNode[i].isActive) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 available = DEFAULT_CAPACITY - allocated;

            if (available == 0) {
                unchecked {
                    ++i;
                }
                continue; // 节点已满，跳过
            }

            // 这次从这个节点分配多少
            uint256 toAllocate = remaining > available ? available : remaining;

            // 记录分配
            _recordAllocation(user, stakeAddress, 4, toAllocate, nodeId);

            remaining -= toAllocate; // 减少还需要分配的金额

            unchecked {
                ++i;
            }
        }
        require(remaining == 0, "No commodity");
    }

    // ==================== 组合分配 ====================

    /**
     * @dev 组合分配节点
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param combination 组合信息（中节点+小节点+商品）
     * 功能：中节点+小节点+商品混合分配，总金额不超过100万
     * 关键：必须在同一个节点内完成所有分配
     */
    function allocateCombinedNodes(
        address user,
        address stakeAddress,
        NodeCombination calldata combination
    ) external nonReentrant onlyAllocationAuthorized whenAllocationNotPaused {
        // 检查参数
        require(
            user != address(0) && stakeAddress != address(0),
            "Invalid addresses"
        );
        require(
            user != stakeAddress,
            "User and stake address cannot be the same"
        );
        require(
            combination.mediumNodes > 0 ||
                combination.smallNodes > 0 ||
                combination.commodity > 0,
            "At least one node or commodity required"
        );

        // 计算总金额：中节点×20万 + 小节点×5万 + 商品金额
        uint256 totalAmount = uint256(combination.mediumNodes) *
            MEDIUM_NODE_AMOUNT +
            uint256(combination.smallNodes) *
            SMALL_NODE_AMOUNT +
            combination.commodity;

        // 总金额必须在1到100万之间
        require(
            totalAmount > 0 && totalAmount <= DEFAULT_CAPACITY,
            "Total must be 1~1,000,000"
        );

        // 在单个节点内完成所有分配
        _allocateCombinedFromSingleNode(
            user,
            stakeAddress,
            combination,
            totalAmount
        );

        // 更新等效值
        _updateEquivalentValue(user, totalAmount, true);

        // ✅ Bug 1 修复：更新用户最后一次分配变化的时间戳
        // 防止通过组合分配路径绕过 MIN_STAKE_DURATION 的防操控保护
        lastAllocationChangeTimestamp[user] = block.timestamp;

        // 触发事件
        emit CombinedNodesAllocated(
            user,
            stakeAddress,
            combination.mediumNodes,
            combination.smallNodes,
            combination.commodity
        );
    }

    /**
     * @dev 在单个节点内完成组合分配
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param combination 组合信息
     * @param totalAmount 总金额
     * 核心：确保一个节点的所有分配加起来不超过100万
     */
    function _allocateCombinedFromSingleNode(
        address user,
        address stakeAddress,
        NodeCombination calldata combination,
        uint256 totalAmount
    ) internal {
        uint256 targetNodeId = 0; // 目标节点ID
        bool found = false; // 是否找到合适节点
        uint256 nodeCount = deployNode.length;

        // 1. 寻找有足够容量的节点
        for (uint256 i = 0; i < nodeCount; ) {
            uint256 nodeId = deployNode[i].id;
            if (isNodeAllocatedAsBig[nodeId]) {
                unchecked {
                    ++i;
                }
                continue; // 跳过已分配为大节点的
            }

            // 跳过非活动节点
            if (nodeIndexById[nodeId] != i) {
                revert NodeIndexCorrupted(nodeId, nodeIndexById[nodeId], i);
            }
            if (!deployNode[i].isActive) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // 计算节点剩余容量
            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 remainingCapacity = DEFAULT_CAPACITY - allocated;

            // 找到剩余容量≥总金额的节点
            if (remainingCapacity >= totalAmount) {
                targetNodeId = nodeId;
                found = true;
                break;
            }

            unchecked {
                ++i;
            }
        }

        // 必须找到有足够容量的节点
        if (!found) revert NoNodeSufficientCapacityForCombinedAllocation();

        // 2. 在找到的节点内依次分配
        // 分配中节点（每个20万）
        if (combination.mediumNodes > 0) {
            for (uint8 i = 0; i < combination.mediumNodes; ) {
                _recordAllocation(
                    user,
                    stakeAddress,
                    2,
                    MEDIUM_NODE_AMOUNT,
                    targetNodeId
                );
                unchecked {
                    ++i;
                }
            }
        }

        // 分配小节点（每个5万）
        if (combination.smallNodes > 0) {
            for (uint8 i = 0; i < combination.smallNodes; ) {
                _recordAllocation(
                    user,
                    stakeAddress,
                    3,
                    SMALL_NODE_AMOUNT,
                    targetNodeId
                );
                unchecked {
                    ++i;
                }
            }
        }

        // 分配商品（任意金额）
        if (combination.commodity > 0) {
            _recordAllocation(
                user,
                stakeAddress,
                4,
                combination.commodity,
                targetNodeId
            );
        }
    }

    // ==================== 核心记录功能 ====================

    /**
     * @dev 记录分配详情
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型
     * @param amount 分配金额
     * @param nodeId 节点ID
     */
    function _recordAllocation(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 amount,
        uint256 nodeId
    ) internal {
        // 限制单个用户的最大分配记录数
        if (userAllocationRecords[user].length >= MAX_USER_ALLOCATIONS) {
            revert AllocationRecordsLimitReached();
        }

        // 确保一个节点的所有分配加起来不超过100万
        uint256 newTotal = nodeTotalAllocated[nodeId] + amount;
        if (newTotal > DEFAULT_CAPACITY) revert NodeAllocationExceedsLimit();

        // 更新节点累计分配金额
        nodeTotalAllocated[nodeId] = newTotal;

        // ✅ 生成唯一 nonce，防止同一区块内相同参数记录误匹配
        uint256 currentNonce = _allocationNonce++;

        // 创建分配记录
        AllocationRecord memory record = AllocationRecord({
            timestamp: block.timestamp,
            user: user,
            stakeAddress: stakeAddress,
            nodeType: nodeType,
            amount: amount,
            nodeId: nodeId,
            nonce: currentNonce
        });

        // 保存到两个地方：1.按用户索引 2.按节点索引
        userAllocationRecords[user].push(record);
        nodeAllocationRecords[nodeId].push(record);

        // 触发分配事件
        emit NodeAllocated(user, stakeAddress, nodeType, amount, nodeId);
    }

    /**
     * @dev 获取用户不同质押地址的数量（用于检查是否会超限）
     * @param user 用户地址
     * @return 不同质押地址的数量
     */
    function getUserStakeAddressCount(
        address user
    ) external view returns (uint256) {
        AllocationRecord[] storage records = userAllocationRecords[user];
        uint256 len = records.length;

        if (len == 0) return 0;
        if (len > MAX_USER_ALLOCATIONS) {
            len = MAX_USER_ALLOCATIONS;
        }

        address[] memory tempAddresses = new address[](len);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < len; ) {
            address stakeAddr = records[i].stakeAddress;

            bool found = false;
            for (uint256 j = 0; j < uniqueCount; ) {
                if (tempAddresses[j] == stakeAddr) {
                    found = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }

            if (!found) {
                tempAddresses[uniqueCount] = stakeAddr;
                unchecked {
                    ++uniqueCount;
                }
            }

            unchecked {
                ++i;
            }
        }

        return uniqueCount;
    }

    /**
     * @dev 更新等效值
     * @param user 用户地址
     * @param amount 分配金额
     * @param isActive 节点是否活跃（分配时节点必须是活跃的）
     * 功能：计算等效值并更新用户和总体的统计
     */
    function _updateEquivalentValue(address user, uint256 amount, bool isActive) internal {
        // 等效值 = (分配金额 × 精度) / 100万
        uint256 equivalent = (amount * SCALE) / DEFAULT_CAPACITY;
        userPhysicalNodesEquivalent[user] += equivalent;
        totalPhysicalNodesEquivalent += equivalent;
        // ✅ Critical: 只有活跃节点才计入奖励分母
        if (isActive) {
            totalActiveEquivalent += equivalent;
        }
    }

    // ==================== 查询功能 ====================

    /**
     * @dev 查询节点详细信息
     * @param nodeId 节点ID
     * @return 节点信息
     */
    function getNodeInfo(
        uint256 nodeId
    ) external view returns (NodeInfo memory) {
        require(nodeId > 0, "No ID");
        uint256 index = nodeIndexById[nodeId];
        require(index < deployNode.length, "No node");
        NodeInfo storage node = deployNode[index];
        require(node.id == nodeId, "ID mismatch");
        return node;
    }

    /**
     * @dev 查询节点剩余容量
     * @param nodeId 节点ID
     * @return 剩余容量
     * 计算：剩余容量 = 100万 - 已分配金额
     */
    function getNodeRemainingCapacity(
        uint256 nodeId
    ) public view returns (uint256) {
        require(nodeId > 0, "No ID");
        require(nodeIndexById[nodeId] < deployNode.length, "No node");
        if (isNodeAllocatedAsBig[nodeId]) return 0; // 大节点已被完全分配
        return DEFAULT_CAPACITY - nodeTotalAllocated[nodeId];
    }

    /**
     * @dev 查询节点已分配总额
     * @param nodeId 节点ID
     * @return 已分配金额
     */
    function getNodeTotalAllocated(
        uint256 nodeId
    ) public view returns (uint256) {
        require(nodeId > 0, "No ID");
        require(nodeIndexById[nodeId] < deployNode.length, "No node");
        return nodeTotalAllocated[nodeId];
    }

    /**
     * @dev 检查是否可以分配指定金额到节点
     * @param nodeId 节点ID
     * @param amount 要分配的金额
     * @return 是否可以分配
     */
    function canAllocateToNode(
        uint256 nodeId,
        uint256 amount
    ) public view returns (bool) {
        if (!nodeExists(nodeId)) return false;

        // 检查节点是否处于活动状态
        uint256 index = nodeIndexById[nodeId];
        if (index >= deployNode.length) return false;
        NodeInfo storage node = deployNode[index];
        if (node.id != nodeId) return false;
        if (!node.isActive) return false;

        if (isNodeAllocatedAsBig[nodeId]) return false; // 大节点不能分配
        return (nodeTotalAllocated[nodeId] + amount) <= DEFAULT_CAPACITY;
    }

    /**
     * @dev 检查节点是否存在
     * @param nodeId 节点ID
     * @return 是否存在
     */
    function nodeExists(uint256 nodeId) public view returns (bool) {
        if (nodeId == 0) return false;
        uint256 index = nodeIndexById[nodeId];
        if (index >= deployNode.length) return false;
        return deployNode[index].id == nodeId;
    }

    /**
     * @dev 验证节点容量一致性（invariant check）
     * @param nodeId 节点ID
     * @return isConsistent 是否一致
     * @return calculatedTotal 从分配记录计算的总金额
     * @return recordedTotal nodeTotalAllocated 记录的值
     * @notice 用于检测状态不一致问题
     */
    function verifyNodeCapacityConsistency(
        uint256 nodeId
    )
        external
        view
        returns (
            bool isConsistent,
            uint256 calculatedTotal,
            uint256 recordedTotal
        )
    {
        if (!nodeExists(nodeId)) {
            return (false, 0, 0);
        }

        recordedTotal = nodeTotalAllocated[nodeId];
        calculatedTotal = 0;

        AllocationRecord[] storage records = nodeAllocationRecords[nodeId];
        uint256 len = records.length;

        for (uint256 i = 0; i < len; ) {
            calculatedTotal += records[i].amount;
            unchecked {
                ++i;
            }
        }

        isConsistent = (calculatedTotal == recordedTotal);
    }

    /**
     * @dev 验证用户等效值一致性
     * @param user 用户地址
     * @return isConsistent 是否一致
     * @return calculatedEquivalent 从分配记录计算的等效值（所有节点，包括非活跃）
     * @return recordedEquivalent userPhysicalNodesEquivalent 记录的值
     * @return activeEquivalent 活跃节点的等效值（用于奖励计算）
     * 注意：userPhysicalNodesEquivalent 包含所有分配记录的等效值
     *       而奖励计算只使用活跃节点的等效值
     */
    function verifyUserEquivalentConsistency(
        address user
    )
        external
        view
        returns (
            bool isConsistent,
            uint256 calculatedEquivalent,
            uint256 recordedEquivalent,
            uint256 activeEquivalent
        )
    {
        recordedEquivalent = userPhysicalNodesEquivalent[user];
        calculatedEquivalent = 0;
        activeEquivalent = 0;

        AllocationRecord[] storage records = userAllocationRecords[user];
        uint256 len = records.length;

        for (uint256 i = 0; i < len; ) {
            // ✅ Bug 3 修复：计算所有分配记录的等效值
            // 这应该与 userPhysicalNodesEquivalent 一致
            uint256 equivalent = (records[i].amount * SCALE) / DEFAULT_CAPACITY;
            calculatedEquivalent += equivalent;

            // ✅ 额外计算活跃节点的等效值（用于奖励计算）
            uint256 nodeId = records[i].nodeId;
            uint256 nodeIndex = nodeIndexById[nodeId];
            if (
                nodeIndex < deployNode.length &&
                deployNode[nodeIndex].id == nodeId &&
                deployNode[nodeIndex].isActive
            ) {
                activeEquivalent += equivalent;
            }

            unchecked {
                ++i;
            }
        }

        // ✅ 比较所有分配记录的等效值与记录值
        isConsistent = (calculatedEquivalent == recordedEquivalent);
    }

    /**
     * @dev 验证全局活跃等效值一致性
     * @param users 用户地址数组（需要调用者提供）
     * @return isConsistent 是否一致
     * @return calculatedActive 从分配记录计算的活跃等效值
     * @return recordedActive totalActiveEquivalent 记录的值
     * ✅ Bug 3 修复：接受用户列表参数，实现真正的遍历校验
     * 注意：这个操作 gas 消耗可能很大，只适合在链下调用
     */
    function verifyActiveEquivalentConsistency(
        address[] calldata users
    )
        external
        view
        returns (
            bool isConsistent,
            uint256 calculatedActive,
            uint256 recordedActive
        )
    {
        recordedActive = totalActiveEquivalent;
        calculatedActive = 0;

        uint256 len = users.length;
        for (uint256 i = 0; i < len; ) {
            address user = users[i];
            if (user == address(0)) {
                unchecked { ++i; }
                continue;
            }

            // 遍历该用户的所有分配记录
            AllocationRecord[] storage records = userAllocationRecords[user];
            uint256 recordLen = records.length;
            for (uint256 j = 0; j < recordLen; ) {
                uint256 nodeId = records[j].nodeId;
                uint256 nodeIndex = nodeIndexById[nodeId];

                // 只计算活跃节点的等效值
                if (
                    nodeIndex < deployNode.length &&
                    deployNode[nodeIndex].id == nodeId &&
                    deployNode[nodeIndex].isActive
                ) {
                    uint256 equivalent = (records[j].amount * SCALE) / DEFAULT_CAPACITY;
                    calculatedActive += equivalent;
                }

                unchecked { ++j; }
            }

            unchecked { ++i; }
        }

        isConsistent = (calculatedActive == recordedActive);
    }

    /**
     * @dev 按用户查询分配记录
     * @param user 用户地址
     * @return 该用户的所有分配记录
     */
    function getUserAllocations(
        address user
    ) external view returns (AllocationRecord[] memory) {
        return userAllocationRecords[user];
    }

    /**
     * @dev 按节点ID查询分配记录
     * @param nodeId 节点ID
     * @return 该节点的所有分配记录
     */
    function getNodeAllocations(
        uint256 nodeId
    ) external view returns (AllocationRecord[] memory) {
        return nodeAllocationRecords[nodeId];
    }

    /**
     * @dev 获取节点统计信息
     * @notice 返回值totalNodes即总节点数、activeNodes即激活节点数、bigNodes即大节点数、totalRemainingCapacity即总剩余容量
     */
    function getNodeStatistics()
        external
        view
        returns (
            uint256 totalNodes,
            uint256 activeNodes,
            uint256 bigNodes,
            uint256 totalRemainingCapacity
        )
    {
        totalNodes = deployNode.length;

        for (uint i = 0; i < totalNodes; ) {
            NodeInfo storage node = deployNode[i];

            if (nodeIndexById[node.id] != i) {
                unchecked {
                    ++i;
                }
                continue;
            }

            if (node.isActive) {
                unchecked {
                    ++activeNodes;
                }
            }

            if (isNodeAllocatedAsBig[node.id]) {
                unchecked {
                    ++bigNodes;
                }
            } else if (node.isActive) {
                // 只统计活动节点的剩余容量，非活动节点不可分配，不应计入
                uint256 remaining = DEFAULT_CAPACITY -
                    nodeTotalAllocated[node.id];
                totalRemainingCapacity += remaining;
            }

            unchecked {
                ++i;
            }
        }

        return (totalNodes, activeNodes, bigNodes, totalRemainingCapacity);
    }

    // ==================== 停止节点分配奖励功能 ====================

    /**
     * @dev 计算节点在当前快照时间点之前的分配等效值
     * @param nodeId 节点ID
     * @return snapshotEquiv 快照时间之前的分配等效值
     * ✅ 修复问题X：用于 setNodeStatus 同步 lastRewardActiveEquivalent
     * ⚠️ 问题AD：此函数 Gas 复杂度 O(n)，n = nodeAllocationRecords[nodeId].length
     * 若某节点被大量用户分配（如1000用户各100条商品记录），setNodeStatus 可能 OOG
     * 实际风险：onlyAllocationAuthorized 限制分配权限，正常运营下不会出现极端情况
     * 建议：运营时保持节点分配颗粒度适中，避免单个节点过多小额分配
     */
    function _getNodeSnapshotEquivalent(uint256 nodeId) internal view returns (uint256 snapshotEquiv) {
        AllocationRecord[] storage records = nodeAllocationRecords[nodeId];
        uint256 cutoff = lastRewardTimestamp;
        uint256 len = records.length;
        for (uint256 i = 0; i < len; ) {
            // 仅计入快照时间之前的分配（与 _getStakeAddressesWithEquivalent 过滤逻辑对齐）
            if (cutoff == 0 || records[i].timestamp < cutoff) {
                snapshotEquiv += (records[i].amount * SCALE) / DEFAULT_CAPACITY;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @dev 管理节点分配和奖励的暂停状态
     * @param _pauseAllocation 是否暂停节点分配
     * @param _pauseReward 是否暂停节点分配奖励
     */
    function setAllocationStatus(
        bool _pauseAllocation,
        bool _pauseReward
    ) external onlyOwner {
        pausedNodeAllocation = _pauseAllocation;
        pausedNodeAllocationReward = _pauseReward;
        emit AllocationStatusChanged(
            msg.sender,
            pausedNodeAllocation,
            pausedNodeAllocationReward
        );
    }

    /**
     * @dev 管理节点状态（暂停/恢复）
     * @param nodeId 节点ID
     * @param isActive 是否激活
     */
    function setNodeStatus(uint256 nodeId, bool isActive) external onlyOwner {
        require(nodeId > 0, "No ID");
        uint256 index = nodeIndexById[nodeId];
        require(index < deployNode.length, "No node");
        NodeInfo storage node = deployNode[index];
        require(node.id == nodeId, "ID mismatch");

        // ✅ Critical: 更新全局活跃等效值
        // 只有状态真正改变时才更新
        if (node.isActive != isActive) {
            // 计算该节点的已分配等效值
            uint256 nodeAllocated = nodeTotalAllocated[nodeId];
            uint256 nodeEquivalent = (nodeAllocated * SCALE) / DEFAULT_CAPACITY;

            // ✅ 修复问题X：计算快照有效等效值，用于同步 lastRewardActiveEquivalent
            // 只计入 timestamp < lastRewardTimestamp 的分配，与 _getStakeAddressesWithEquivalent 过滤逻辑对齐
            uint256 snapshotEquiv = _getNodeSnapshotEquivalent(nodeId);

            if (isActive) {
                // 节点被激活：增加活跃等效值
                totalActiveEquivalent += nodeEquivalent;
                // ✅ 修复问题X：同步更新快照，只加快照有效部分
                if (lastRewardTimestamp > 0) {
                    lastRewardActiveEquivalent += snapshotEquiv;
                }
            } else {
                // 节点被暂停：减少活跃等效值
                require(totalActiveEquivalent >= nodeEquivalent, "Active equivalent underflow");
                totalActiveEquivalent -= nodeEquivalent;
                // ✅ 修复问题X：同步更新快照，只减快照有效部分
                if (lastRewardTimestamp > 0) {
                    if (lastRewardActiveEquivalent >= snapshotEquiv) {
                        lastRewardActiveEquivalent -= snapshotEquiv;
                    } else {
                        lastRewardActiveEquivalent = 0;
                    }
                }
            }
        }

        node.isActive = isActive;

        emit NodeStatusChanged(nodeId, isActive);
    }

    /**
     * @dev 从用户的分配记录中获取质押地址及其对应的等效值
     * @param user 用户地址
     * @return stakeAddresses 质押地址数组
     * @return equivalents 等效值数组
     * @return totalStakeEquivalent 总等效值
     * @return stakeAddressLimitExceeded 质押地址数量是否超限（用于 configRewards 跳过该用户）
     * ✅ 修复问题AA：将 revert 改为返回标志，避免整批奖励失败
     */
    function _getStakeAddressesWithEquivalent(
        address user
    ) internal view returns (
        address[] memory stakeAddresses,
        uint256[] memory equivalents,
        uint256 totalStakeEquivalent,
        bool stakeAddressLimitExceeded
    ) {
        AllocationRecord[] storage records = userAllocationRecords[user];
        uint256 len = records.length;

        // ✅ 清理低危问题7：删除死代码
        // _recordAllocation 已限制记录数不超过 MAX_USER_ALLOCATIONS，此处检查永远不会生效
        // 保留注释说明：如果未来移除 _recordAllocation 的限制，需要恢复此检查

        address[] memory tempAddresses = new address[](len);
        uint256[] memory tempEquivalents = new uint256[](len);

        uint256 uniqueCount = 0;
        totalStakeEquivalent = 0;
        stakeAddressLimitExceeded = false;

        // ✅ 获取上一次奖励时间戳，防止 Reward Timing Attack
        uint256 lastReward = lastRewardTimestamp;

        // ✅ 修复问题Y和问题Z：使用 hasDistributedReward 作为哨兵，并提升到循环外
        bool isFirstReward = !hasDistributedReward;

        for (uint256 i = 0; i < len; ) {
            AllocationRecord storage record = records[i];

            // ✅ 防止 Reward Timing Attack：
            // 如果有上一次奖励，只有在上一次奖励之前就已存在的分配才能参与本次奖励
            // ✅ 修复问题Y：使用 hasDistributedReward 作为哨兵，防止 lastRewardActiveEquivalent 降至 0 后被重置
            if (!isFirstReward && record.timestamp >= lastReward) {
                unchecked { ++i; }
                continue;
            }

            // ✅ Critical 修复：防止首次奖励时同一区块内分配+奖励攻击
            // 即使是首次奖励，也要求分配记录不在当前区块
            // 这防止攻击者在同一区块内先分配巨额等效值，然后立即调用 configRewards
            if (isFirstReward && record.timestamp == block.timestamp) {
                unchecked { ++i; }
                continue;
            }

            uint256 nodeId = record.nodeId;

            uint256 nodeIndex = nodeIndexById[nodeId];
            if (nodeIndex >= deployNode.length || deployNode[nodeIndex].id != nodeId) {
                revert NodeIndexCorrupted(nodeId, nodeIndex, nodeIndex < deployNode.length ? deployNode[nodeIndex].id : type(uint256).max);
            }

            if (!deployNode[nodeIndex].isActive) {
                unchecked { ++i; }
                continue;
            }

            uint256 equivalent = (record.amount * SCALE) / DEFAULT_CAPACITY;
            if (equivalent == 0) {
                unchecked { ++i; }
                continue;
            }

            address stakeAddr = record.stakeAddress;

            bool found = false;
            for (uint256 j = 0; j < uniqueCount; ) {
                if (tempAddresses[j] == stakeAddr) {
                    tempEquivalents[j] += equivalent;
                    totalStakeEquivalent += equivalent;
                    found = true;
                    break;
                }
                unchecked { ++j; }
            }

            if (!found) {
                // ✅ 修复问题AA：限制单个用户的质押地址数量，防止 gas DoS 和地址拆分攻击
                // 超限时截断并标记，不 revert，避免整批奖励失败
                if (uniqueCount >= MAX_STAKE_ADDRESSES) {
                    stakeAddressLimitExceeded = true;
                    // ✅ 修复问题AF：超限时不再累加 totalStakeEquivalent
                    // 确保返回值 totalStakeEquivalent == sum(equivalents[])
                    // 继续处理已有记录，但不添加新的质押地址
                    // 该用户将在 configRewards 中被跳过
                } else {
                    tempAddresses[uniqueCount] = stakeAddr;
                    tempEquivalents[uniqueCount] = equivalent;
                    totalStakeEquivalent += equivalent;
                    unchecked { ++uniqueCount; }
                }
            }

            unchecked { ++i; }
        }

        stakeAddresses = new address[](uniqueCount);
        equivalents = new uint256[](uniqueCount);

        for (uint256 i = 0; i < uniqueCount; ) {
            stakeAddresses[i] = tempAddresses[i];
            equivalents[i] = tempEquivalents[i];
            unchecked { ++i; }
        }
    }

    /**
     * @dev 从用户的分配记录中获取质押地址及其对应的等效值（外部查询接口）
     * @param user 用户地址
     * @return 质押地址数组和对应的等效值数组
     */
    function getStakeAddressesWithEquivalent(
        address user
    ) external view returns (address[] memory, uint256[] memory, uint256) {
        (address[] memory stakeAddresses, uint256[] memory equivalents, uint256 totalStakeEquivalent, ) = _getStakeAddressesWithEquivalent(user);
        return (stakeAddresses, equivalents, totalStakeEquivalent);
    }

    // ==================== 奖励分发功能 ====================

    function _safeRewardTransfer(address to, uint256 amount) internal {
        if (to == address(0) || amount == 0) return;
        TransferHelper.safeTransferETH(to, amount);
    }

    /**
     * @dev 分发奖励给用户
     * @param _users 用户地址数组（最多20个，受 MAX_REWARD_USERS 限制）
     * 要求：1.每人每天只能领一次 2.奖励按等效值比例分配 3.50%给用户，50%给质押地址
     */
    function configRewards(
        address[] calldata _users
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        whenNodeAllocationRewardNotPaused
    {
        uint256 length = _users.length;
        require(
            length > 0 && length <= MAX_REWARD_USERS,
            "Invalid users count"
        );

        // ===== 1️⃣ 获取今日奖励信息 =====
        (
            uint256 dailyReward,
            uint16 currentYear,
            uint256 currentDay
        ) = _getCurrentRewardInfo();
        require(dailyReward > 0, "No reward");
        // ✅ 限制每日奖励上限，防止奖励计算器异常导致资金损失
        require(dailyReward <= MAX_DAILY_REWARD, "Reward exceeds limit");

        // ===== 2️⃣ 第一轮：计算有效总等效值并缓存质押信息 =====
        // ✅ Bug 1 & Bug 2 修复：分母计算逻辑
        // - 首次奖励（hasDistributedReward == false）：使用当前 totalActiveEquivalent
        // - 后续奖励：使用上一次奖励时的快照值 lastRewardActiveEquivalent
        // ✅ 修复问题Y：使用 hasDistributedReward 作为哨兵，防止 lastRewardActiveEquivalent 降至 0 后被重置
        bool isFirstReward = !hasDistributedReward;
        uint256 globalEffectiveTotal = isFirstReward 
            ? totalActiveEquivalent 
            : lastRewardActiveEquivalent;

        // ✅ 缓存每个用户的等效值和质押信息，避免第二轮重复调用
        uint256[] memory allTotalEquivalents = new uint256[](length);
        UserStakeCache[] memory stakeCaches = new UserStakeCache[](length);

        for (uint256 i = 0; i < length; ) {
            address user = _users[i];
            if (user == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // 当天已领取，跳过
            if (lastRewardDay[user][currentYear] >= currentDay) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // ✅ 防止 Allocation State Manipulation Attack：
            // 用户必须在奖励前 MIN_STAKE_DURATION 内没有改变分配状态
            // 这确保攻击者无法在奖励前临时增加分配来获取更多奖励
            // ✅ 修复问题C：移除 lastReward > 0 的前置条件
            // 由于 initialize 时已设置 lastRewardTimestamp，此条件永远为 true
            // 现在首次奖励也受 MIN_STAKE_DURATION 保护
            uint256 lastChange = lastAllocationChangeTimestamp[user];
            uint256 lastReward = lastRewardTimestamp;
            if (lastChange > lastReward && block.timestamp < lastChange + MIN_STAKE_DURATION) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // ✅ 去重：检查同一批次内是否已经处理过该地址
            bool isDuplicate = false;
            for (uint256 k = 0; k < i; ) {
                if (_users[k] == user) {
                    isDuplicate = true;
                    break;
                }
                unchecked {
                    ++k;
                }
            }
            if (isDuplicate) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // ✅ 获取并缓存该用户 active 节点的质押信息
            // ✅ 修复问题AA：检测 stakeAddressLimitExceeded 标志，跳过异常用户
            (
                address[] memory _stakeAddresses,
                uint256[] memory _equivalents,
                uint256 _userActiveEquivalent,
                bool _stakeAddressLimitExceeded
            ) = _getStakeAddressesWithEquivalent(user);

            // ✅ 修复问题AA & AB：质押地址超限时跳过该用户并 emit 事件
            if (_stakeAddressLimitExceeded) {
                emit RewardUserSkipped(user, 1); // reason=1: StakeAddressLimitExceeded
                unchecked {
                    ++i;
                }
                continue;
            }

            allTotalEquivalents[i] = _userActiveEquivalent;
            stakeCaches[i] = UserStakeCache({
                stakeAddresses: _stakeAddresses,
                equivalents: _equivalents,
                totalEquivalent: _userActiveEquivalent
            });

            unchecked {
                ++i;
            }
        }

        // ✅ Critical: 使用全局活跃等效值，如果小于 BASENODE 则补底
        if (globalEffectiveTotal < (BASENODE * SCALE)) {
            globalEffectiveTotal = BASENODE * SCALE;
        }

        require(globalEffectiveTotal > 0, "No total");

        // ===== 3️⃣ 第二轮：计算所有用户应得奖励 =====
        uint256[] memory userRewards = new uint256[](length);
        uint256 totalRewardNeeded = 0;

        for (uint256 i = 0; i < length; ) {
            uint256 userActiveEquivalent = allTotalEquivalents[i];
            if (userActiveEquivalent == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // ✅ Critical: 使用全局活跃等效值作为分母
            uint256 reward = (dailyReward * userActiveEquivalent) /
                globalEffectiveTotal;
            if (reward == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            userRewards[i] = reward;
            totalRewardNeeded += reward;

            unchecked {
                ++i;
            }
        }

        // ✅ 将 rounding remainder 留在合约中，用于下一次奖励
        // 这样可以防止 dust capture attack，同时保持公平
        // remainder = dailyReward - totalRewardNeeded 会留在合约余额中
        // 下一次奖励时会被自动包含在可用余额中

        // ===== 4️⃣ 余额兜底 =====
        require(
            totalRewardNeeded <= dailyReward,
            "Total reward exceeds daily limit"
        );

        require(
            address(this).balance >= totalRewardNeeded,
            "Insufficient contract balance"
        );

        // ===== 5️⃣ 第三轮：实际分发奖励（使用缓存的质押信息）=====
        uint256 usersProcessed = 0;
        uint256 totalDistributed = 0;

        for (uint256 i = 0; i < length; ) {
            uint256 totalReward = userRewards[i];
            if (totalReward == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            address user = _users[i];

            // 防止同批次重复
            if (lastRewardDay[user][currentYear] >= currentDay) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // ✅ 使用缓存的质押信息，避免重复调用 getStakeAddressesWithEquivalent
            UserStakeCache memory cache = stakeCaches[i];
            uint256 totalStakeEquivalent = cache.totalEquivalent;

            if (totalStakeEquivalent == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // ===== 记录已领取, 先更新状态 =====
            lastRewardDay[user][currentYear] = currentDay;

            // ===== 奖励拆分：50% 用户 + 50% 质押 =====
            uint256 userReward = totalReward / 2;
            uint256 stakeRewardPool = totalReward - userReward;

            // ---- 给用户 ----
            _safeRewardTransfer(user, userReward);

            // ---- 给质押地址（按等效值比例）----
            uint256 stakeLength = cache.stakeAddresses.length;
            for (uint256 j = 0; j < stakeLength; ) {
                address stakeAddr = cache.stakeAddresses[j];
                if (stakeAddr == address(0)) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }

                uint256 stakeReward = (stakeRewardPool * cache.equivalents[j]) /
                    totalStakeEquivalent;
                if (stakeReward == 0) {
                    unchecked {
                        ++j;
                    }
                    continue;
                }
                // 给质押地址
                _safeRewardTransfer(stakeAddr, stakeReward);

                emit StakeRewardDistributed(
                    user,
                    stakeAddr,
                    stakeReward,
                    currentYear
                );

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++usersProcessed;
                ++i;
            }
            totalDistributed += totalReward;

            emit RewardDistributed(user, userReward, currentYear);
        }

        // ✅ Bug 1 修复：只有在有用户被处理时才更新时间边界
        // 防止空批次调用静默推进时间边界
        // 注意：不 revert，只是跳过更新，保持原有状态
        if (usersProcessed > 0) {
            // ✅ 修复问题Y：设置已分发奖励标志
            hasDistributedReward = true;

            // ✅ 更新上一次奖励时间戳，用于下一次奖励的 Timing Attack 防护
            // 下一次奖励只会计算此时间戳之前的分配
            lastRewardTimestamp = block.timestamp;

            // ✅ Bug 2 修复：更新活跃等效值快照
            // 下一次奖励使用此快照作为分母，确保分母与分子的时间过滤一致
            lastRewardActiveEquivalent = totalActiveEquivalent;
        }

        emit BatchRewardsDistributed(
            usersProcessed,
            totalDistributed,
            currentYear
        );
    }

    /**
     * @dev 获取当前奖励信息
     * @return dailyReward 每日奖励金额
     * @return currentYear 当前年份
     * @return currentDay 当前天数
     * 注意：此函数会更新 lastGlobalRewardDay 和 lastDailyRewardSnapshot
     * ✅ 修复问题AC：同一天多批次调用使用相同的 dailyReward 快照
     */
    function _getCurrentRewardInfo()
        internal
        returns (uint256 dailyReward, uint16 currentYear, uint256 currentDay)
    {
        // 调用内部 view 函数获取数据
        (uint256 _dailyReward, uint16 _currentYear, uint256 _currentDay) = _getCurrentRewardInfoView();

        // ✅ 防止 currentDay 倒退（重复领取攻击）
        require(_currentDay >= lastGlobalRewardDay, "Day down");
        
        // ✅ 修复问题AC：新的一天时更新快照，同一天使用快照值
        if (_currentDay > lastGlobalRewardDay) {
            lastGlobalRewardDay = _currentDay;
            lastDailyRewardSnapshot = _dailyReward;
            dailyReward = _dailyReward;
        } else {
            // 同一天，使用快照值
            // ✅ 修复问题AH：升级场景下 lastDailyRewardSnapshot == 0，使用实时值
            if (lastDailyRewardSnapshot == 0) {
                dailyReward = _dailyReward;
            } else {
                dailyReward = lastDailyRewardSnapshot;
            }
        }
        
        currentYear = _currentYear;
        currentDay = _currentDay;

        return (dailyReward, currentYear, currentDay);
    }

    /**
     * @dev 获取当前奖励信息
     * @return dailyReward 每日奖励金额
     * @return currentYear 当前年份
     * @return currentDay 当前天数
     */
    function _getCurrentRewardInfoView()
        internal
        view
        returns (uint256 dailyReward, uint16 currentYear, uint256 currentDay)
    {
        // ✅ 先获取当前天数
        (bool successDay, bytes memory dataDay) = REWARD.staticcall(
            abi.encodeWithSignature("getDaysSinceDeployment()")
        );
        require(successDay, "Call failed");
        require(dataDay.length >= 32, "Bad data");

        currentDay = abi.decode(dataDay, (uint256));
        require(currentDay > 0, "Day > 0");

        // ✅ 然后获取该天的奖励（会触发事件，但我们用 staticcall 所以不会执行）
        (bool successReward, bytes memory dataReward) = REWARD.staticcall(
            abi.encodeWithSignature("getDailyReward(uint256)", currentDay)
        );
        require(successReward, "Call failed");
        require(dataReward.length >= 32, "Bad data");

        dailyReward = abi.decode(dataReward, (uint256));

        // ✅ 计算当前年份（假设每年365天）
        // 先用 uint256 计算，校验后再强转，避免截断后检查形同虚设
        uint256 yearRaw = ((currentDay - 1) / 365) + 1;
        require(yearRaw <= type(uint16).max, "Year overflow");
        currentYear = uint16(yearRaw);

        return (dailyReward, currentYear, currentDay);
    }

    /**
     * @dev 获取当前奖励信息
     * @return dailyReward 每日奖励金额
     * @return currentYear 当前年份
     * @return currentDay 当前天数
     */
    function getCurrentRewardInfo()
        public
        view
        returns (uint256 dailyReward, uint16 currentYear, uint256 currentDay)
    {
        return _getCurrentRewardInfoView();
    }

    /**
     * @dev 暂停所有奖励分发
     */
    function pauseRewards() external onlyOwner {
        _pause();
        emit RewardStatusChanged(msg.sender, true);
    }

    /**
     * @dev 恢复所有奖励分发
     */
    function unpauseRewards() external onlyOwner {
        _unpause();
        emit RewardStatusChanged(msg.sender, false);
    }

    /**
     * @dev 紧急暂停奖励分发（独立于全局暂停）
     * @notice 这是一个紧急功能，可以快速停止奖励分发而不影响其他功能
     */
    function emergencyPauseRewardDistribution() external onlyOwner {
        pausedNodeAllocationReward = true;
        emit AllocationStatusChanged(msg.sender, pausedNodeAllocation, true);
    }

    /**
     * @dev 恢复奖励分发
     */
    function resumeRewardDistribution() external onlyOwner {
        pausedNodeAllocationReward = false;
        emit AllocationStatusChanged(msg.sender, pausedNodeAllocation, false);
    }

    // ==================== 其他功能 ====================
    /**
     * @dev 查询合约余额
     */
    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev 查询当前白名单数量
     * @return 白名单人数
     */
    function getWhitelistCount() external view returns (uint256) {
        return currentWhitelistCount;
    }

    receive() external payable {}

    // ==================== 多签提款功能 ====================

    /**
     * @dev 添加多签用户
     * @param _signer 要添加的签名用户地址
     */
    function addWithdrawSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) {
            revert InvalidSignerAddress();
        }
        if (isWithdrawSigner[_signer]) {
            revert SignerAlreadyExists();
        }
        withdrawSigners.push(_signer);
        isWithdrawSigner[_signer] = true;
        emit WithdrawSignerAdded(_signer);
    }

    /**
     * @dev 移除多签用户
     * @param _signer 移除签名用户地址
     * @notice 如果签名者有未执行的已确认提案，需要先执行或等待过期
     */
    function removeWithdrawSigner(address _signer) external onlyOwner {
        require(isWithdrawSigner[_signer], "not signer");

        cleanupExpiredProposals(EXPIRED_PROPOSAL_CLEANUP_STEPS);

        uint256 len = withdrawSigners.length;

        // ✅ 防止删除后签名者数量低于阈值（防止单签风险）
        if (len <= withdrawThreshold) {
            revert CannotRemoveSignerBelowThreshold();
        }

        // ✅ 防止移除有未执行且未过期提案确认的签名者
        // 倒序仅扫描“未过期窗口”内提案，避免固定窗口漏检
        for (uint256 i = nextWithdrawProposalId; i > 0; ) {
            unchecked {
                --i;
            }

            WithdrawProposal storage p = withdrawProposals[i];
            if (p.amount == 0 || p.executed || withdrawProposalFinalized[i]) {
                continue;
            }

            if (block.timestamp > p.createdAt + PROPOSAL_EXPIRY_TIME) {
                break;
            }

            if (withdrawalConfirmations[i][_signer]) {
                revert SignerHasPendingConfirmations();
            }
        }

        // 从签名者列表中移除
        bool found = false;
        for (uint i = 0; i < len; ) {
            if (withdrawSigners[i] == _signer) {
                withdrawSigners[i] = withdrawSigners[len - 1];
                withdrawSigners.pop();
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (!found) {
            revert SignerNotFoundInArray();
        }
        delete isWithdrawSigner[_signer];
        // ✅ 修复中危问题3：重置活跃提案计数器，防止重新添加时计数偏高
        signerActiveProposalCount[_signer] = 0;

        emit WithdrawSignerRemoved(_signer);
    }

    /**
     * @dev 更新多签阈值
     * @param _newThreshold 新的阈值
     */
    function updateWithdrawThreshold(uint256 _newThreshold) external onlyOwner {
        // ✅ Bug B 修复：移除死代码（_newThreshold == 0 已被 <= 1 覆盖）
        if (_newThreshold > withdrawSigners.length) {
            revert ThresholdExceedsSigners();
        }
        // ✅ 防止阈值设置为 0 或 1（单签风险）
        if (_newThreshold <= 1) {
            revert ThresholdMustBeGreaterThanOne();
        }

        uint256 oldThreshold = withdrawThreshold;
        withdrawThreshold = _newThreshold;

        emit WithdrawThresholdUpdated(oldThreshold, _newThreshold);
    }

    function _finalizeWithdrawProposal(uint256 proposalId) internal {
        if (withdrawProposalFinalized[proposalId]) return;

        withdrawProposalFinalized[proposalId] = true;

        if (activeWithdrawProposalCount > 0) {
            activeWithdrawProposalCount -= 1;
        }

        address proposer = withdrawProposals[proposalId].proposer;
        if (proposer != address(0) && signerActiveProposalCount[proposer] > 0) {
            signerActiveProposalCount[proposer] -= 1;
        }
    }

    function cleanupExpiredProposals(uint256 maxSteps) public {
        require(maxSteps > 0, "maxSteps > 0");
        // ✅ 限制清理步数上限，防止 gas 攻击
        require(maxSteps <= MAX_CLEANUP_STEPS, "maxSteps exceeds limit");

        uint256 proposalCount = nextWithdrawProposalId;
        if (proposalCount == 0) {
            withdrawProposalCleanupCursor = 0;
            return;
        }

        uint256 cursor = withdrawProposalCleanupCursor;
        if (cursor == 0 || cursor > proposalCount) {
            cursor = proposalCount;
        }

        // ✅ 记录扫描过的提案数量，用于检测是否完成一整圈
        // 当 scanned >= proposalCount 时，说明已经扫描了所有提案
        uint256 totalScanned = 0;

        uint256 scanned = 0;
        while (scanned < maxSteps && totalScanned < proposalCount) {
            // ✅ 先判零重置，再递减
            // 这样 cursor 访问范围是 N-1 到 0，不会漏掉 proposals[0]
            if (cursor == 0) {
                cursor = proposalCount;
            }
            unchecked {
                --cursor;
                ++scanned;
                ++totalScanned;
            }

            WithdrawProposal storage p = withdrawProposals[cursor];
            if (
                p.amount == 0 || p.executed || withdrawProposalFinalized[cursor]
            ) {
                continue;
            }

            if (block.timestamp > p.createdAt + PROPOSAL_EXPIRY_TIME) {
                _finalizeWithdrawProposal(cursor);
                emit WithdrawProposalExpired(cursor);
            }
        }

        withdrawProposalCleanupCursor = cursor;
    }

    /**
     * @dev 创建提款提案
     * @param _amount 提款金额
     * @param _to 收款地址
     * @return 提案ID
     */
    function createWithdrawProposal(
        uint256 _amount,
        address _to
    ) external onlyWithdrawMultiSig returns (uint256) {
        require(_amount > 0, "Amount > 0");
        require(_to != address(0), "Invalid recipient");

        cleanupExpiredProposals(EXPIRED_PROPOSAL_CLEANUP_STEPS);

        if (activeWithdrawProposalCount >= MAX_ACTIVE_WITHDRAW_PROPOSALS) {
            revert TooManyActiveWithdrawProposals();
        }
        if (
            signerActiveProposalCount[msg.sender] >=
            MAX_SIGNER_ACTIVE_WITHDRAW_PROPOSALS
        ) {
            revert SignerActiveProposalLimitExceeded();
        }

        // 倒序仅扫描“未过期窗口”内提案
        for (uint256 i = nextWithdrawProposalId; i > 0; ) {
            unchecked {
                --i;
            }

            WithdrawProposal storage p = withdrawProposals[i];
            if (p.amount == 0 || p.executed || withdrawProposalFinalized[i]) {
                continue;
            }

            if (block.timestamp > p.createdAt + PROPOSAL_EXPIRY_TIME) {
                break;
            }

            if (p.amount == _amount && p.to == _to) {
                revert DuplicateProposalExists();
            }
        }

        // 注意：此处不校验余额。从创建到执行最多间隔7天，期间余额可能变化，
        // 余额充足性由 executeWithdrawProposal 在执行时校验。

        uint256 proposalId = nextWithdrawProposalId++;
        withdrawProposals[proposalId] = WithdrawProposal({
            amount: _amount,
            to: _to,
            createdAt: block.timestamp,
            confirmations: 0,
            executed: false,
            proposer: msg.sender
        });

        activeWithdrawProposalCount += 1;
        signerActiveProposalCount[msg.sender] += 1;

        emit WithdrawProposalCreated(proposalId, _amount, _to);
        return proposalId;
    }

    /**
     * @dev 确认提款提案
     * @param proposalId 提案ID
     */
    function confirmWithdrawProposal(
        uint256 proposalId
    ) external onlyWithdrawMultiSig {
        WithdrawProposal storage proposal = withdrawProposals[proposalId];
        require(proposal.amount > 0, "No proposal");
        require(!proposal.executed, "Executed");
        // ✅ 修复中危问题4：检查提案是否已被清理标记为 finalized
        require(!withdrawProposalFinalized[proposalId], "Finalized");
        require(
            block.timestamp <= proposal.createdAt + PROPOSAL_EXPIRY_TIME,
            "Expired"
        );
        require(!withdrawalConfirmations[proposalId][msg.sender], "Confirmed");

        withdrawalConfirmations[proposalId][msg.sender] = true;
        require(
            proposal.confirmations < withdrawSigners.length,
            "Confirmations overflow"
        );
        proposal.confirmations++;

        emit WithdrawProposalConfirmed(proposalId, msg.sender);
    }

    /**
     * @dev 执行提款提案
     * @param proposalId 提案ID
     */
    function executeWithdrawProposal(
        uint256 proposalId
    ) external onlyWithdrawMultiSig nonReentrant {
        WithdrawProposal storage proposal = withdrawProposals[proposalId];
        require(proposal.amount > 0, "No proposal");
        require(!proposal.executed, "Executed");
        require(
            block.timestamp <= proposal.createdAt + PROPOSAL_EXPIRY_TIME,
            "Expired"
        );
        require(proposal.confirmations >= withdrawThreshold, "No confirms");

        require(proposal.amount <= address(this).balance, "No balance");

        // 先更新状态再交互
        proposal.executed = true;
        _finalizeWithdrawProposal(proposalId);

        // 再转账
        TransferHelper.safeTransferETH(proposal.to, proposal.amount);

        emit WithdrawProposalExecuted(proposalId, proposal.amount, proposal.to);
    }

    /**
     * @dev 查询签名用户是否已确认提案
     * @param proposalId 提案ID
     * @param signer 签名用户地址
     * @return 是否已确认
     */
    function isProposalConfirmed(
        uint256 proposalId,
        address signer
    ) external view returns (bool) {
        return withdrawalConfirmations[proposalId][signer];
    }

    /**
     * @dev 获取所有签名用户
     * @return 签名用户列表
     */
    function getWithdrawSigners() external view returns (address[] memory) {
        return withdrawSigners;
    }

    /**
     * @dev 获取签名用户数量
     * @return 签名用户数量
     */
    function getWithdrawSignerCount() external view returns (uint256) {
        return withdrawSigners.length;
    }

    /**
     * @dev 获取过期提案清理游标状态
     * @return cursor 当前游标
     * @return proposalCount 当前提案总数（nextWithdrawProposalId）
     * @return activeCount 当前活跃提案数
     */
    function getCleanupCursorState()
        external
        view
        returns (uint256 cursor, uint256 proposalCount, uint256 activeCount)
    {
        return (
            withdrawProposalCleanupCursor,
            nextWithdrawProposalId,
            activeWithdrawProposalCount
        );
    }

    /**
     * @dev Storage gap for future upgrades
     * ✅ 保留 40 slot 用于未来升级，防止 storage 冲突
     */
    uint256[40] private __gap;
}
