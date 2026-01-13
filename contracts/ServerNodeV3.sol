// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

// 生成节点ID
library Counters {
    struct Counter {
        uint256 _value;
    }

    function current(Counter storage counter) internal view returns (uint256) {
        return counter._value;
    }

    function increment(Counter storage counter) internal {
        unchecked { counter._value += 1; }
    }
}

/**
 * @title 服务器节点管理合约
 * @notice 管理节点创建、分配、奖励、暂停等所有功能
 * @dev 可升级，确保安全可靠
 */
contract ServerNodeV3 is
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
    uint256 public constant SECONDS_PER_DAY = 86400; // 一天多少秒
    uint256 private constant SCALE = 1e6; // 精度放大倍数，用来算等效值

    // ====== 核心数据 ======
    using Counters for Counters.Counter;
    Counters.Counter private _counter; // 用来生成节点ID的计数器

    address private REWARD; // 奖励计算器的地址
    uint256 public totalPhysicalNodesEquivalent; // 所有人总共买了多少节点的等效值
    NodeInfo[] public deployNode; // 所有已创建的节点

    mapping(address => uint256) public userPhysicalNodesEquivalent; // 每个人买了多少节点的等效值
    mapping(address => mapping(uint16 => uint256)) public lastRewardDay; // 每个人每年最后领奖励是哪天

    // ====== 节点信息结构 ======
    struct NodeInfo {
        string ip; // IP地址
        string name; // 节点名称
        bool isActive; // 是否激活
        address nodeStakeAddress; // 节点质押地址
        uint256 capacity;        // 固定 1_000_000
        uint256 allocated;       // 已占用容量
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
        address user;
        uint8   nodeType;   // 1=大 2=中 3=小 4=商品
        uint256 amount;     // 占用容量
        uint256 nodeId;     // 物理节点
    }


    // 批量分配的结构
    struct Allocation {
    address user;     // 用户地址（占用节点的人）
    uint8   nodeType; // 1=大节点 2=中节点 3=小节点 4=商品
    uint256 quantity; // 节点数量（仅 nodeType 1/2/3 使用）
    uint256 amount;   // 金额（仅 nodeType=4 商品使用）
}

    mapping(address => AllocationRecord[]) public userAllocationRecords;
    mapping(uint256 => AllocationRecord[]) public nodeAllocationRecords;

    // ====== 各种映射和数组 ======
    mapping(address => bool) public whiteList; // 白名单
    uint8 public currentWhitelistCount; // 当前白名单人数

    mapping(string => uint256) public nodeIdByIP; // 通过IP查节点ID
    mapping(uint256 => uint256) public nodeIndexById; // 通过节点ID查索引

    // ====== 多签相关 ======
    uint256 public withdrawThreshold; // 多签阈值
    address[] public withdrawSigners; // 多签签名人列表
    mapping(address => bool) public isWithdrawSigner; // 是否是签名人
    uint256 public nextWithdrawProposalId; // 下一个提款提案ID
    struct WithdrawProposal {
        uint256 amount;
        address to;
        uint256 createdAt;
        uint256 confirmations;
        bool executed;
    }
    mapping(uint256 => WithdrawProposal) public withdrawProposals; // 提款提案
    mapping(uint256 => mapping(address => bool)) public withdrawalConfirmations; // 提款确认

    // ====== 控制开关 ======
    bool public pausedNodeAllocation; // 节点分配是否暂停
    bool public pausedNodeAllocationReward; // 节点分配奖励是否暂停

    // ====== 权限修饰符 ======

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
        require(!pausedNodeAllocation, "Node allocation is paused");
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

    // 只有多签签名人才能调用
    modifier onlyWithdrawMultiSig() {
        require(isWithdrawSigner[msg.sender], "Not a withdraw signer");
        _;
    }

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
    event AllocationStatusChanged(address indexed admin, bool paused, bool isRewardPaused);
    event WhitelistUpdated(address indexed user, bool added);
    event CombinedNodesAllocated(
        address indexed user,
        address indexed stakeAddress,
        uint8 mediumNodes,
        uint8 smallNodes,
        uint256 commodity
    );
    event NodeAllocated(address indexed user, address indexed stakeAddress, uint8 nodeType, uint256 amount, uint256 nodeId);
    event NodeDeallocated(address indexed user, address indexed stakeAddress, uint8 nodeType, uint256 amount, uint256 nodeId);
    event StakeRewardDistributed(address indexed user, address indexed stakeAddress, uint256 amount, uint16 year);
    event RewardDistributed(address indexed user, uint256 amount, uint16 year);
    event BatchRewardsDistributed(uint256 count, uint256 totalAmount, uint16 year);
    event RewardStatusChanged(address indexed admin, bool paused);
    event WithdrawSignerAdded(address indexed signer);
    event WithdrawSignerRemoved(address indexed signer);
    event WithdrawProposalCreated(uint256 indexed proposalId, uint256 amount, address to);
    event WithdrawProposalConfirmed(uint256 indexed proposalId, address indexed signer);
    event WithdrawProposalExecuted(uint256 indexed proposalId, uint256 amount, address to);
    event WithdrawMultiSigInitialized(address[] signers, uint256 threshold);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev 初始化
     * @param _owner 合约管理员
     * @param _rewardCalculator 奖励计算器地址
     * @param _withdrawSigners 多签签名人列表
     * @param _withdrawThreshold 多签阈值
     */
    function initialize(
        address _owner,
        address _rewardCalculator,
        address[] calldata _withdrawSigners,
        uint256 _withdrawThreshold
    ) public initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();

        require(_owner != address(0), "Owner address is zero");
        require(
            _rewardCalculator != address(0),
            "Reward calculator address is zero"
        );
        uint256 length = _withdrawSigners.length;
        require(length > 0, "Signers list is empty");
        require(_withdrawThreshold > 0, "Threshold must be greater than 0");
        require(_withdrawThreshold <= length, "Threshold exceeds signers count");

        // 设置奖励计算器
        REWARD = _rewardCalculator;

        // 初始化多签系统
        for (uint i = 0; i < length; i++) {
            require(_withdrawSigners[i] != address(0), "Invalid signer address");
            require(!isWithdrawSigner[_withdrawSigners[i]], "Signer already exists");
            withdrawSigners.push(_withdrawSigners[i]);
            isWithdrawSigner[_withdrawSigners[i]] = true;
            emit WithdrawSignerAdded(_withdrawSigners[i]);
        }

        withdrawThreshold = _withdrawThreshold;
        emit WithdrawMultiSigInitialized(_withdrawSigners, _withdrawThreshold);
    }

    // ==================== 1）节点创建与管理 ====================
    /**
     * @dev 创建新节点（只有管理员能调用）
     * @param _nodeInfo 要创建的节点信息数组
     * 功能：1.检查IP是否唯一 2.设置固定容量100万 3.记录节点信息
     */
   function createNode(
    NodeInfo[] calldata _nodeInfo
) external onlyOwner nonReentrant {
    uint256 len = _nodeInfo.length;
    require(len > 0, "empty input");

    for (uint256 i = 0; i < len; i++) {
        NodeInfo calldata n = _nodeInfo[i];

        require(n.nodeStakeAddress != address(0), "invalid stake address");

        _counter.increment();
        uint256 nodeId = _counter.current();


        deployNode.push(
            NodeInfo({
                id: nodeId,
                name: n.name,
                ip: n.ip,
                isActive: true,
                nodeStakeAddress: n.nodeStakeAddress,
                capacity: DEFAULT_CAPACITY, // 固定 1_000_000
                allocated: 0,               // 初始为 0
                createTime: block.timestamp
            })
        );

      require(nodeIdByIP[n.ip] == 0, "IP already exists");
        // 通过IP记录节点ID，方便后续查询
       nodeIdByIP[n.ip] = nodeId;

        nodeIndexById[nodeId] = deployNode.length - 1;
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
        require(user != address(0), "Invalid user address");

        if (_isTrue) {
            // 添加白名单
            require(
                currentWhitelistCount < MAX_WHITELIST,
                "Max whitelist limit reached"
            );
            require(!whiteList[user], "User already whitelisted");
            whiteList[user] = true;
            currentWhitelistCount++;
        } else {
            // 移除白名单
            if (whiteList[user]) {
                whiteList[user] = false;
                currentWhitelistCount--;
            }
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
    uint256 len = allocations.length;
    require(len > 0 && len <= 20, "invalid batch size");

    for (uint256 i = 0; i < len; i++) {
        Allocation calldata a = allocations[i];

        require(a.user != address(0), "invalid user");
        require(a.nodeType >= 1 && a.nodeType <= 4, "invalid nodeType");

        if (a.nodeType == 1) {
            _allocateBigNodes(a.user, a.quantity);
        } else if (a.nodeType == 2) {
            _allocateSizedNodes(a.user, a.quantity, 200_000, 2);
        } else if (a.nodeType == 3) {
            _allocateSizedNodes(a.user, a.quantity, 50_000, 3);
        } else {
            require(a.amount > 0 && a.amount <= DEFAULT_CAPACITY, "invalid amount");
            _allocateCommodity(a.user, a.amount);
        }
    }
}


    /**
     * @dev 取消分配单个节点（外部调用）
     * @param user 用户地址
     * @param nodeType 节点类型
     * @param amount 分配金额
     * @param nodeId 节点ID
     * 功能：取消之前的节点分配，从记录中移除并更新节点容量
     */
    function deallocateNodes(
    address user,
    uint8 nodeType,
    uint256 amount,
    uint256 nodeId
) external onlyOwner whenNotPaused {
    require(user != address(0), "invalid user");
    require(nodeId > 0, "invalid nodeId");
    require(amount > 0, "invalid amount");

    uint256 index = nodeIndexById[nodeId];
    require(index < deployNode.length, "node not found");

    NodeInfo storage node = deployNode[index];
    require(node.id == nodeId, "nodeId mismatch");

    /* ===== 1️⃣ 从用户记录中移除 ===== */
    AllocationRecord[] storage uRecords = userAllocationRecords[user];
    bool foundUser;

    for (uint256 i = 0; i < uRecords.length; i++) {
        AllocationRecord storage r = uRecords[i];
        if (
            r.nodeId == nodeId &&
            r.nodeType == nodeType &&
            r.amount == amount
        ) {
            uRecords[i] = uRecords[uRecords.length - 1];
            uRecords.pop();
            foundUser = true;
            break;
        }
    }
    require(foundUser, "user allocation not found");

    /* ===== 2️⃣ 从节点记录中移除 ===== */
    AllocationRecord[] storage nRecords = nodeAllocationRecords[nodeId];
    bool foundNode;

    for (uint256 i = 0; i < nRecords.length; i++) {
        AllocationRecord storage r = nRecords[i];
        if (
            r.user == user &&
            r.nodeType == nodeType &&
            r.amount == amount
        ) {
            nRecords[i] = nRecords[nRecords.length - 1];
            nRecords.pop();
            foundNode = true;
            break;
        }
    }
    require(foundNode, "node allocation not found");

    /* ===== 3️⃣ 回滚节点容量 ===== */
    require(node.allocated >= amount, "node allocated underflow");
    node.allocated -= amount;

    emit NodeDeallocated(
        user,
        node.nodeStakeAddress,
        nodeType,
        amount,
        nodeId
    );
}


    /**
     * @dev 单次分配节点
     * @param user 用户地址
     * @param nodeType 节点类型（1=大节点，2=中节点，3=小节点，4=商品）
     * @param quantity 数量（用于大/中/小节点）
     * @param amount 金额（用于商品）
     */
    function allocateNodes(
    address user,
    uint8 nodeType,
    uint256 quantity,
    uint256 amount
) external onlyAllocationAuthorized whenAllocationNotPaused {
    require(user != address(0), "invalid user");
    require(nodeType >= 1 && nodeType <= 4, "invalid nodeType");

    if (nodeType == 1) {
        _allocateBigNodes(user, quantity);
    } else if (nodeType == 2) {
        _allocateSizedNodes(user, quantity, 200_000, 2);
    } else if (nodeType == 3) {
        _allocateSizedNodes(user, quantity, 50_000, 3);
    } else {
        require(amount > 0 && amount <= 1_000_000, "invalid amount");
        _allocateCommodity(user, amount);
    }
}

    // ==================== 核心分配逻辑 ====================

    /**
     * @dev 分配大节点（内部函数）
     * @param user 用户地址
     * @param quantity 要分配几个大节点
     * 条件：1.节点类型必须为1 2.节点未被分配过 3.节点剩余容量为100万
     */
    function _allocateBigNodes(
    address user,
    uint256 quantity
) internal {
    uint256 allocatedCount;

    for (uint256 i = 0; i < deployNode.length && allocatedCount < quantity; i++) {
        NodeInfo storage node = deployNode[i];

        if (!node.isActive) continue;
        if (node.allocated != 0) continue;

        node.allocated = node.capacity;

        _recordAllocation(
            user,
            1,
            node.capacity,
            node.id
        );

        _increaseEquivalent(user, node.capacity);
        allocatedCount++;
    }

    require(allocatedCount == quantity, "insufficient big nodes");
}


  //中小节点
  function _allocateSizedNodes(
    address user,
    uint256 quantity,
    uint256 unit,
    uint8 nodeType
) internal {
    uint256 remaining = quantity;

    for (uint256 i = 0; i < deployNode.length && remaining > 0; i++) {
        NodeInfo storage node = deployNode[i];
        if (!node.isActive) continue;

        uint256 free = node.capacity - node.allocated;
        if (free < unit) continue;

        uint256 canAllocate = free / unit;
        uint256 count = remaining < canAllocate ? remaining : canAllocate;

        for (uint256 j = 0; j < count; j++) {
            node.allocated += unit;

            _recordAllocation(
                user,
                nodeType,
                unit,
                node.id
            );

            _increaseEquivalent(user, unit);
        }

        remaining -= count;
    }

    require(remaining == 0, "insufficient capacity");
}


    /**
     * @dev 分配商品（内部函数）
     * @param user 用户地址
     * @param amount 商品金额（1-100万）
     * 条件：从剩余容量≥投资金额的节点中分配，可以跨多个节点
     */
 function _allocateCommodity(
    address user,
    uint256 amount
) internal {
    uint256 remaining = amount;

    for (uint256 i = 0; i < deployNode.length && remaining > 0; i++) {
        NodeInfo storage node = deployNode[i];
        if (!node.isActive) continue;

        uint256 free = node.capacity - node.allocated;
        if (free == 0) continue;

        uint256 used = remaining < free ? remaining : free;
        node.allocated += used;

        _recordAllocation(
            user,
            4,
            used,
            node.id
        );

        _increaseEquivalent(user, used);
        remaining -= used;
    }

    require(remaining == 0, "insufficient capacity");
}


function _increaseEquivalent(address user, uint256 amount) internal {
    uint256 eq = (amount * SCALE) / DEFAULT_CAPACITY;
    userPhysicalNodesEquivalent[user] += eq;
    totalPhysicalNodesEquivalent += eq;
}

/**
 * @dev 组合分配：中节点 + 小节点 + 商品（原子操作）
 * @param user 用户地址
 * @param combo 组合分配参数
 */
function allocateCombinedNodes(
    address user,
    NodeCombination calldata combo
)
    external
    onlyAllocationAuthorized
    whenAllocationNotPaused
    nonReentrant
{
    require(user != address(0), "invalid user");

    // 至少要有一种分配
    require(
        combo.mediumNodes > 0 ||
        combo.smallNodes > 0 ||
        combo.commodity > 0,
        "empty combination"
    );

    // 商品合法性
    if (combo.commodity > 0) {
        require(
            combo.commodity <= DEFAULT_CAPACITY,
            "commodity too large"
        );
    }

    // 中节点：20万
    if (combo.mediumNodes > 0) {
        _allocateSizedNodes(
            user,
            combo.mediumNodes,
            200_000,
            2
        );
    }

    // 小节点：5万
    if (combo.smallNodes > 0) {
        _allocateSizedNodes(
            user,
            combo.smallNodes,
            50_000,
            3
        );
    }

    // 商品
    if (combo.commodity > 0) {
        _allocateCommodity(
            user,
            combo.commodity
        );
    }

    emit CombinedNodesAllocated(
        user,
        address(0), // ⚠️ stakeAddress 不在这里体现（按 node 走）
        combo.mediumNodes,
        combo.smallNodes,
        combo.commodity
    );
}


    // ==================== 核心记录功能 ====================

    /**
     * @dev 记录分配详情（内部函数）
     * @param user 用户地址
     * @param nodeType 节点类型
     * @param amount 分配金额
     * @param nodeId 节点ID
     * 功能：1.检查是否超过100万限制 2.更新累计分配 3.保存记录
     */
    function _recordAllocation(
    address user,
    uint8 nodeType,
    uint256 amount,
    uint256 nodeId
) internal {
    AllocationRecord memory record = AllocationRecord({
        user: user,
        nodeType: nodeType,
        amount: amount,
        nodeId: nodeId
    });

    userAllocationRecords[user].push(record);
    nodeAllocationRecords[nodeId].push(record);

    NodeInfo storage node = deployNode[nodeIndexById[nodeId]];

    emit NodeAllocated(
        user,
        node.nodeStakeAddress,
        nodeType,
        amount,
        nodeId
    );
}


    // ==================== 查询功能 ====================

    /**
     * @dev 查询节点详细信息
     * @param nodeId 节点ID
     * @return 节点信息
     * 优化：使用映射直接查找，速度更快
     */
    function getNodeInfo(
        uint256 nodeId
    ) external view returns (NodeInfo memory) {
        // 检查nodeId有效性（nodeId从1开始）
        require(nodeId > 0, "Invalid node ID");
        // 通过映射直接找到节点在数组中的位置
        uint256 index = nodeIndexById[nodeId];
        require(index < deployNode.length, "Node not found");
        NodeInfo storage node = deployNode[index];
        require(node.id == nodeId, "Node ID mismatch");
        return node;
    }

    /**
     * @dev 查询节点剩余容量
     * @param nodeId 节点ID
     * @return 剩余容量
     * 计算：剩余容量 = 100万 - 已分配金额
     */
    function getNodeRemainingCapacity(uint256 nodeId)
    public
    view
    returns (uint256)
    {
        require(nodeId > 0, "Invalid node ID");
        uint256 index = nodeIndexById[nodeId];
        require(index < deployNode.length, "Node does not exist");

        NodeInfo storage node = deployNode[index];
        if (!node.isActive) return 0;

        return node.capacity - node.allocated;
    }


    /**
     * @dev 查询节点已分配总额
     * @param nodeId 节点ID
     * @return 已分配金额
     */
    function getNodeTotalAllocated(uint256 nodeId)
    public
    view
    returns (uint256)
{
    require(nodeId > 0, "Invalid node ID");
    uint256 index = nodeIndexById[nodeId];
    require(index < deployNode.length, "Node does not exist");

    return deployNode[index].allocated;
}


    /**
     * @dev 检查是否可以分配指定金额到节点
     * @param nodeId 节点ID
     * @param amount 要分配的金额
     * @return 是否可以分配
     */
    function canAllocateToNode(uint256 nodeId, uint256 amount)
    public
    view
    returns (bool)
{
    if (!nodeExists(nodeId)) return false;

    NodeInfo storage node = deployNode[nodeIndexById[nodeId]];
    if (!node.isActive) return false;

    return node.allocated + amount <= node.capacity;
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

    for (uint256 i = 0; i < totalNodes; i++) {
        NodeInfo storage node = deployNode[i];

        if (node.isActive) activeNodes++;

        if (node.allocated == node.capacity) {
            bigNodes++;
        } else {
            totalRemainingCapacity += (node.capacity - node.allocated);
        }
    }
}


    // ==================== 停止节点分配奖励功能 ====================

    /**
     * @dev 管理节点分配和奖励的暂停状态（只有管理员能调用）
     * @param _pauseAllocation 是否暂停节点分配
     * @param _pauseReward 是否暂停节点分配奖励
     */
    function setAllocationStatus(bool _pauseAllocation, bool _pauseReward) external onlyOwner {
        pausedNodeAllocation = _pauseAllocation;
        pausedNodeAllocationReward = _pauseReward;
        emit AllocationStatusChanged(msg.sender, pausedNodeAllocation, pausedNodeAllocationReward);
    }

    /**
     * @dev 管理节点状态（暂停/恢复）（只有管理员能调用）
     * @param nodeId 节点ID
     * @param isActive 是否暂停
     */
    function setNodeStatus(uint256 nodeId, bool isActive) external onlyOwner {
        require(nodeId > 0, "Invalid node ID");
        uint256 index = nodeIndexById[nodeId];
        require(index < deployNode.length, "Node not found");
        NodeInfo storage node = deployNode[index]; 
        require(node.id == nodeId, "Node ID mismatch");
        node.isActive = isActive;

        emit NodeStatusChanged(nodeId, isActive);
    }

    /**
     * @dev 从用户的分配记录中获取质押地址及其对应的等效值
     * @param user 用户地址
     * @return 质押地址数组和对应的等效值数组
     */
   function getStakeAddressesWithEquivalent(address user)
    public
    view
    returns (address[] memory, uint256[] memory, uint256)
{
    AllocationRecord[] storage records = userAllocationRecords[user];
    require(records.length <= 200, "too many allocations");
    uint256 len = records.length;

    address[] memory tmpAddr = new address[](len);
    uint256[] memory tmpEq = new uint256[](len);
    uint256 count;
    uint256 totalEq;

    for (uint256 i = 0; i < len; i++) {
        AllocationRecord storage r = records[i];
        NodeInfo storage node = deployNode[nodeIndexById[r.nodeId]];

        if (!node.isActive) continue;

        uint256 eq = (r.amount * SCALE) / DEFAULT_CAPACITY;
        if (eq == 0) continue;

        totalEq += eq;

        bool found;
        for (uint256 j = 0; j < count; j++) {
            if (tmpAddr[j] == node.nodeStakeAddress) {
                tmpEq[j] += eq;
                found = true;
                break;
            }
        }

        if (!found) {
            tmpAddr[count] = node.nodeStakeAddress;
            tmpEq[count] = eq;
            count++;
        }
    }

    address[] memory addrs = new address[](count);
    uint256[] memory eqs = new uint256[](count);
    for (uint256 i = 0; i < count; i++) {
        addrs[i] = tmpAddr[i];
        eqs[i] = tmpEq[i];
    }

    return (addrs, eqs, totalEq);
}





// ==================== 奖励分发功能 ====================

function _safeRewardTransfer(address to, uint256 amount) internal {
    require(!pausedNodeAllocationReward, "reward paused");
    if (to == address(0) || amount == 0) return;

    uint256 balance = address(this).balance;
    if (amount > balance) amount = balance;

    TransferHelper.safeTransferETH(to, amount);
}

    /**
     * @dev 分发奖励给用户（只有管理员能调用）
     * @param users 用户地址数组（最多50个）
     * 规则：1.每人每天只能领一次 2.奖励按等效值比例分配 3.50%给用户，50%给质押地址
     */
    function configRewards(address[] calldata users)
    external
    onlyOwner
    nonReentrant
    whenNotPaused
    whenNodeAllocationRewardNotPaused
{
    (uint256 dailyReward, uint16 year, uint256 day) =
        getCurrentRewardInfo();

    uint256 effectiveTotal =
        totalPhysicalNodesEquivalent < (BASENODE * SCALE)
            ? (BASENODE * SCALE)
            : totalPhysicalNodesEquivalent;

    for (uint256 i = 0; i < users.length; i++) {
        address user = users[i];
        if (lastRewardDay[user][year] >= day) continue;

        (
            address[] memory stakeAddrs,
            uint256[] memory eqs,
            uint256 totalStakeEq
        ) = getStakeAddressesWithEquivalent(user);

        // ⚠️ 关键：只认活跃节点
        if (totalStakeEq == 0) continue;

        uint256 reward = (dailyReward * totalStakeEq) / effectiveTotal;
        if (reward == 0) continue;

        uint256 userPart = reward / 2;
        uint256 stakePool = reward - userPart;

        _safeRewardTransfer(user, userPart);

        for (uint256 j = 0; j < stakeAddrs.length; j++) {
            uint256 part = (stakePool * eqs[j]) / totalStakeEq;
            _safeRewardTransfer(stakeAddrs[j], part);
        }

        lastRewardDay[user][year] = day;
    }
}



    /**
     * @dev 获取当前奖励信息
     * @return dailyReward 每日奖励金额
     * @return currentYear 当前年份
     * @return currentDay 当前天数
     */
    function getCurrentRewardInfo()
        public
        returns (uint256 dailyReward, uint16 currentYear, uint256 currentDay)
    {
        // 调用奖励计算器获取数据
        (bool success, bytes memory data) = REWARD.call(
            abi.encodeWithSignature("getCurrentDailyReward()")
        );
        require(success, "Failed to get current daily reward");

        (dailyReward, currentDay) = abi.decode(data, (uint256, uint256));

        // 防止currentDay为0导致的下溢
        require(currentDay > 0, "Current day must be greater than 0");

        // 计算当前年份（假设每年365天，最多30年）
        currentYear = uint16(((currentDay - 1) / 365) + 1);
        if (currentYear > 30) currentYear = 30;

        return (dailyReward, currentYear, currentDay);
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

    // ==================== 其他功能 ====================
    /**
     * @dev 查询合约余额
     * @return 合约当前的ETH余额
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
     * @dev 添加多签签名人
     * @param _signer 要添加的签名人地址
     */
    function addWithdrawSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "Invalid address");
        require(!isWithdrawSigner[_signer], "Already a signer");
        withdrawSigners.push(_signer);
        isWithdrawSigner[_signer] = true;
        emit WithdrawSignerAdded(_signer);
    }

    /**
     * @dev 移除多签签名人
     * @param _signer 要移除的签名人地址
     */
    function removeWithdrawSigner(address _signer) external onlyOwner {
        require(isWithdrawSigner[_signer], "not signer");

        uint256 len = withdrawSigners.length;
        for (uint i; i < len; i++) {
            if (withdrawSigners[i] == _signer) {
                withdrawSigners[i] = withdrawSigners[len - 1];
                withdrawSigners.pop();
                break;
            }
        }

        delete isWithdrawSigner[_signer];

        require(withdrawThreshold <= withdrawSigners.length, "threshold invalid");
        emit WithdrawSignerRemoved(_signer);
    }

    /**
     * @dev 创建提款提案
     * @param _amount 提款金额
     * @param _to 收款地址
     * @return 提案ID
     */
    function createWithdrawProposal(uint256 _amount, address _to) external onlyWithdrawMultiSig returns (uint256) {
        require(_amount > 0, "Amount must be greater than 0");
        require(_to != address(0), "Invalid recipient address");
        require(_amount <= address(this).balance, "Insufficient balance");

        uint256 proposalId = nextWithdrawProposalId++;
        withdrawProposals[proposalId] = WithdrawProposal({
            amount: _amount,
            to: _to,
            createdAt: block.timestamp,
            confirmations: 0,
            executed: false
        });

        emit WithdrawProposalCreated(proposalId, _amount, _to);
        return proposalId;
    }

    /**
     * @dev 确认提款提案
     * @param proposalId 提案ID
     */
    function confirmWithdrawProposal(uint256 proposalId) external onlyWithdrawMultiSig {
        WithdrawProposal storage proposal = withdrawProposals[proposalId];
        require(proposal.amount > 0, "Proposal does not exist");
        require(!proposal.executed, "Proposal already executed");
        require(!withdrawalConfirmations[proposalId][msg.sender], "Already confirmed");

        withdrawalConfirmations[proposalId][msg.sender] = true;
        proposal.confirmations++;

        emit WithdrawProposalConfirmed(proposalId, msg.sender);
    }

    /**
     * @dev 执行提款提案
     * @param proposalId 提案ID
     */
    function executeWithdrawProposal(uint256 proposalId) external onlyWithdrawMultiSig nonReentrant {
        WithdrawProposal storage proposal = withdrawProposals[proposalId];
        require(proposal.amount > 0, "Proposal does not exist");
        require(!proposal.executed, "Proposal already executed");
        require(proposal.confirmations >= withdrawThreshold, "Not enough confirmations");
        require(proposal.amount <= address(this).balance, "Insufficient balance");

        proposal.executed = true;
        TransferHelper.safeTransferETH(proposal.to, proposal.amount);

        emit WithdrawProposalExecuted(proposalId, proposal.amount, proposal.to);
    }

    /**
     * @dev 查询签名人是否已确认提案
     * @param proposalId 提案ID
     * @param signer 签名人地址
     * @return 是否已确认
     */
    function isProposalConfirmed(uint256 proposalId, address signer) external view returns (bool) {
        return withdrawalConfirmations[proposalId][signer];
    }

    /**
     * @dev 获取所有签名人
     * @return 签名人列表
     */
    function getWithdrawSigners() external view returns (address[] memory) {
        return withdrawSigners;
    }

    /**
     * @dev 获取签名人数量
     * @return 签名人数量
     */
    function getWithdrawSignerCount() external view returns (uint256) {
        return withdrawSigners.length;
    }
}