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
    }

    // 批量分配的结构
    struct Allocation {
        address user; // 用户地址
        address stakeAddress; // 质押地址
        uint8 nodeType; // 节点类型
        uint256 quantity; // 数量（用于大/中/小节点）
        uint256 amount; // 金额（用于商品）
    }

    // ====== 各种映射和数组 ======
    mapping(address => bool) public whiteList; // 白名单
    uint8 public currentWhitelistCount; // 当前白名单人数

    mapping(uint256 => uint256) public nodeTotalAllocated; // 每个节点总共分配了多少金额（关键）
    mapping(uint256 => bool) public isNodeAllocatedAsBig; // 节点是否被分配成大节点了

    mapping(address => AllocationRecord[]) public userAllocationRecords; // 每个人的分配记录
    mapping(uint256 => AllocationRecord[]) public nodeAllocationRecords; // 每个节点的分配记录

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
    ) public onlyOwner nonReentrant {
        uint256 length = _nodeInfo.length;
        require(length > 0, "Node information cannot be empty");
        require(
            deployNode.length + length <= BIGNODE,
            "Exceeds max physical nodes (2000)"
        );

        for (uint256 i = 0; i < length; i++) {
            // 1. 检查IP地址是否唯一
            require(nodeIdByIP[_nodeInfo[i].ip] == 0, "IP address must be unique");

            require(
                _nodeInfo[i].nodeStakeAddress != address(0),
                "Node stake address must be set"
            );

            // 2. 所有节点容量固定为100万
            uint256 capacity = DEFAULT_CAPACITY;

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
                    createTime: _nodeInfo[i].createTime == 0
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
                capacity
            );
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
        uint256 length = allocations.length;
        require(length <= 20, "Max 20 allocations per batch");

        // 逐个处理每个分配请求
        for (uint i = 0; i < length; i++) {
            _processAllocation(
                allocations[i].user,
                allocations[i].stakeAddress,
                allocations[i].nodeType,
                allocations[i].quantity,
                allocations[i].amount
            );
        }
    }

    /**
     * @dev 取消分配单个节点（外部调用）
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
    ) external onlyOwner whenNotPaused {
        // 检查参数
        require(user != address(0), "Invalid user");
        require(stakeAddress != address(0), "Invalid stake address");
        require(nodeId > 0, "Invalid node ID");
        require(amount > 0, "Invalid amount");

        // 检查节点是否存在
        bool exists = false;
        for (uint i = 0; i < deployNode.length; i++) {
            if (deployNode[i].id == nodeId) {
                exists = true;
                break;
            }
        }
        require(exists, "Node does not exist");

        // 从用户分配记录中移除
        AllocationRecord[] storage userRecords = userAllocationRecords[user];
        bool found = false;
        for (uint i = 0; i < userRecords.length; i++) {
            AllocationRecord storage record = userRecords[i];
            if (
                record.stakeAddress == stakeAddress &&
                record.nodeType == nodeType &&
                record.amount == amount &&
                record.nodeId == nodeId
            ) {
                // 移除记录
                userRecords[i] = userRecords[userRecords.length - 1];
                userRecords.pop();
                found = true;
                break;
            }
        }
        require(found, "Allocation record not found for user");

        // 从节点分配记录中移除
        AllocationRecord[] storage nodeRecords = nodeAllocationRecords[nodeId];
        bool nodeRecordFound = false;
        for (uint i = 0; i < nodeRecords.length; i++) {
            AllocationRecord storage record = nodeRecords[i];
            if (
                record.user == user &&
                record.stakeAddress == stakeAddress &&
                record.nodeType == nodeType &&
                record.amount == amount
            ) {
                // 移除记录
                nodeRecords[i] = nodeRecords[nodeRecords.length - 1];
                nodeRecords.pop();
                nodeRecordFound = true;
                break;
            }
        }
        require(nodeRecordFound, "Allocation record not found for node");

        // 更新节点累计分配金额
        require(
            nodeTotalAllocated[nodeId] >= amount,
            "Insufficient allocated amount to deallocate"
        );
        nodeTotalAllocated[nodeId] -= amount;

        // 如果是大节点且分配金额为100万，重置大节点标记
        if (nodeType == 1 && amount == DEFAULT_CAPACITY) {
            isNodeAllocatedAsBig[nodeId] = false;
        }

        // 触发取消分配事件
        emit NodeDeallocated(user, stakeAddress, nodeType, amount, nodeId);
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
     * @dev 处理单个分配请求（内部函数）
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
        require(user != address(0), "Invalid user");
        require(stakeAddress != address(0), "Invalid stake address");
        require(
            user != stakeAddress,
            "User and stake address cannot be the same"
        );
        require(nodeType >= 1 && nodeType <= 4, "Invalid node type");

        if (nodeType == 4) {
            // 商品分配：金额1-100万，数量必须为0
            require(
                amount >= 1 && amount <= 1_000_000,
                "Amount must be 1-1,000,000"
            );
            require(quantity == 0, "Quantity must be 0 for commodity");
            _allocateCommodity(user, stakeAddress, amount); // 分配商品
            _updateEquivalentValue(user, amount); // 更新等效值
        } else {
            // 大/中/小节点：数量必须大于0，金额必须为0
            require(quantity > 0, "Quantity must be > 0");
            require(amount == 0, "Amount must be 0 for node types 1-3");

            if (nodeType == 1) {
                // 大节点：整机独占100万
                _allocateBigNodes(user, stakeAddress, quantity);
            } else if (nodeType == 2) {
                // 中节点：每个20万
                uint256 totalAmount = quantity * 200_000;
                _allocateMediumNodes(user, stakeAddress, quantity);
                _updateEquivalentValue(user, totalAmount);
            } else if (nodeType == 3) {
                // 小节点：每个5万
                uint256 totalAmount = quantity * 50_000;
                _allocateSmallNodes(user, stakeAddress, quantity);
                _updateEquivalentValue(user, totalAmount);
            }
        }
    }

    // ==================== 核心分配逻辑 ====================

    /**
     * @dev 分配大节点（内部函数）
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
        for (uint i = 0; i < deployNode.length && allocated < quantity; i++) {
            uint256 nodeId = deployNode[i].id;

            // 检查节点是否符合分配条件
            if (
                !isNodeAllocatedAsBig[nodeId] && // 没被分配过大节点
                nodeTotalAllocated[nodeId] == 0 // 没分配过任何金额
            ) {
                // 标记为大节点（不能在这里设置nodeTotalAllocated，_recordAllocation会处理）
                isNodeAllocatedAsBig[nodeId] = true;

                // 记录分配（内部会更新nodeTotalAllocated）
                _recordAllocation(
                    user,
                    stakeAddress,
                    1,
                    DEFAULT_CAPACITY,
                    nodeId
                );

                // 更新等效值
                _updateEquivalentValue(user, DEFAULT_CAPACITY);

                allocated++; // 已分配数量加1
            }
        }
        require(allocated == quantity, "Insufficient available big nodes");
    }

    /**
     * @dev 分配中节点（内部函数）
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
        uint256 requiredCapacity = 200_000; // 每个中节点需要20万容量

        // 遍历所有节点
        for (uint i = 0; i < deployNode.length && remaining > 0; i++) {
            uint256 nodeId = deployNode[i].id;

            // 跳过已被分配为大节点的节点
            if (isNodeAllocatedAsBig[nodeId]) continue;

            // 计算节点剩余容量
            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 available = DEFAULT_CAPACITY - allocated;

            // 如果节点剩余容量≥20万，可以分配中节点
            if (available >= requiredCapacity) {
                // 计算这个节点最多能分配几个中节点
                uint256 maxFromThisNode = available / requiredCapacity;
                // 实际分配数量 = min(还需要分配的数量, 这个节点能分配的最大数量)
                uint256 allocateCount = remaining > maxFromThisNode
                    ? maxFromThisNode
                    : remaining;

                // 为每个中节点创建一条分配记录
                for (uint j = 0; j < allocateCount; j++) {
                    _recordAllocation(
                        user,
                        stakeAddress,
                        2,
                        requiredCapacity,
                        nodeId
                    );
                }

                remaining -= allocateCount; // 减少还需要分配的数量
            }
        }
        require(remaining == 0, "Insufficient capacity for medium nodes");
    }

    /**
     * @dev 分配小节点（内部函数）
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
        uint256 requiredCapacity = 50_000; // 每个小节点需要5万容量

        for (uint i = 0; i < deployNode.length && remaining > 0; i++) {
            uint256 nodeId = deployNode[i].id;
            if (isNodeAllocatedAsBig[nodeId]) continue;

            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 available = DEFAULT_CAPACITY - allocated;

            if (available >= requiredCapacity) {
                uint256 maxFromThisNode = available / requiredCapacity;
                uint256 allocateCount = remaining > maxFromThisNode
                    ? maxFromThisNode
                    : remaining;

                for (uint j = 0; j < allocateCount; j++) {
                    _recordAllocation(
                        user,
                        stakeAddress,
                        3,
                        requiredCapacity,
                        nodeId
                    );
                }

                remaining -= allocateCount;
            }
        }
        require(remaining == 0, "Insufficient capacity for small nodes");
    }

    /**
     * @dev 分配商品（内部函数）
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

        for (uint i = 0; i < deployNode.length && remaining > 0; i++) {
            uint256 nodeId = deployNode[i].id;
            if (isNodeAllocatedAsBig[nodeId]) continue;

            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 available = DEFAULT_CAPACITY - allocated;

            if (available == 0) continue; // 节点已满，跳过

            // 这次从这个节点分配多少
            uint256 toAllocate = remaining > available ? available : remaining;

            // 记录分配
            _recordAllocation(user, stakeAddress, 4, toAllocate, nodeId);

            remaining -= toAllocate; // 减少还需要分配的金额
        }
        require(remaining == 0, "Insufficient capacity for commodity");
    }

    // ==================== 组合分配 ====================

    /**
     * @dev 组合分配节点（外部调用）
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
    ) external onlyAllocationAuthorized whenAllocationNotPaused {
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
            200_000 +
            uint256(combination.smallNodes) *
            50_000 +
            combination.commodity;

        // 总金额必须在1到100万之间
        require(
            totalAmount > 0 && totalAmount <= 1_000_000,
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
        _updateEquivalentValue(user, totalAmount);

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
     * @dev 在单个节点内完成组合分配（内部函数）
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

        // 1. 寻找有足够容量的节点
        for (uint256 i = 0; i < deployNode.length; i++) {
            uint256 nodeId = deployNode[i].id;
            if (isNodeAllocatedAsBig[nodeId]) continue; // 跳过已分配为大节点的

            // 计算节点剩余容量
            uint256 allocated = nodeTotalAllocated[nodeId];
            uint256 remaining = DEFAULT_CAPACITY - allocated;

            // 找到剩余容量≥总金额的节点
            if (remaining >= totalAmount) {
                targetNodeId = nodeId;
                found = true;
                break;
            }
        }

        // 必须找到有足够容量的节点
        require(
            found,
            "No node has sufficient capacity for combined allocation"
        );

        // 2. 在找到的节点内依次分配
        // 分配中节点（每个20万）
        if (combination.mediumNodes > 0) {
            for (uint8 i = 0; i < combination.mediumNodes; i++) {
                _recordAllocation(user, stakeAddress, 2, 200_000, targetNodeId);
            }
        }

        // 分配小节点（每个5万）
        if (combination.smallNodes > 0) {
            for (uint8 i = 0; i < combination.smallNodes; i++) {
                _recordAllocation(user, stakeAddress, 3, 50_000, targetNodeId);
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
     * @dev 记录分配详情（内部函数）
     * @param user 用户地址
     * @param stakeAddress 质押地址
     * @param nodeType 节点类型
     * @param amount 分配金额
     * @param nodeId 节点ID
     * 功能：1.检查是否超过100万限制 2.更新累计分配 3.保存记录
     */
    function _recordAllocation(
        address user,
        address stakeAddress,
        uint8 nodeType,
        uint256 amount,
        uint256 nodeId
    ) internal {
        // 关键检查：确保一个节点的所有分配加起来不超过100万
        uint256 newTotal = nodeTotalAllocated[nodeId] + amount;
        require(
            newTotal <= DEFAULT_CAPACITY,
            "Node total allocation exceeds 1,000,000 limit"
        );

        // 更新节点累计分配金额
        nodeTotalAllocated[nodeId] = newTotal;

        // 创建分配记录
        AllocationRecord memory record = AllocationRecord({
            timestamp: block.timestamp,
            user: user,
            stakeAddress: stakeAddress,
            nodeType: nodeType,
            amount: amount,
            nodeId: nodeId
        });

        // 保存到两个地方：1.按用户索引 2.按节点索引
        userAllocationRecords[user].push(record);
        nodeAllocationRecords[nodeId].push(record);

        // 触发分配事件
        emit NodeAllocated(user, stakeAddress, nodeType, amount, nodeId);
    }

    /**
     * @dev 更新等效值（内部函数）
     * @param user 用户地址
     * @param amount 分配金额
     * 功能：计算等效值并更新用户和总体的统计
     */
    function _updateEquivalentValue(address user, uint256 amount) internal {
        // 等效值 = (分配金额 × 精度) / 100万
        uint256 equivalent = (amount * SCALE) / DEFAULT_CAPACITY;
        userPhysicalNodesEquivalent[user] += equivalent;
        totalPhysicalNodesEquivalent += equivalent;
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
        require(deployNode[index].id == nodeId, "Node index mismatch");
        return deployNode[index];
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
        require(nodeId > 0, "Invalid node ID");
        require(
            nodeIndexById[nodeId] < deployNode.length,
            "Node does not exist"
        );
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
        require(nodeId > 0, "Invalid node ID");
        require(
            nodeIndexById[nodeId] < deployNode.length,
            "Node does not exist"
        );
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

        // 遍历所有节点计算统计
        for (uint i = 0; i < totalNodes; i++) {
            NodeInfo storage node = deployNode[i];
            if (node.isActive) activeNodes++;
            if (isNodeAllocatedAsBig[node.id]) bigNodes++;
            else totalRemainingCapacity += getNodeRemainingCapacity(node.id);
        }

        return (totalNodes, activeNodes, bigNodes, totalRemainingCapacity);
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
     * @param _pause 是否暂停
     */
    function setNodeStatus(uint256 nodeId, bool _pause) external onlyOwner {
        require(nodeId > 0, "Invalid node ID");
        uint256 index = nodeIndexById[nodeId];
        require(index < deployNode.length, "Node not found");
        require(deployNode[index].id == nodeId, "Node index mismatch");
        
        deployNode[index].isActive = !_pause;
        emit NodeStatusChanged(nodeId, _pause);
    }

    /**
     * @dev 从用户的分配记录中获取质押地址及其对应的等效值
     * @param user 用户地址
     * @return 质押地址数组和对应的等效值数组
     */
    function getStakeAddressesWithEquivalent(address user) internal view returns (address[] memory, uint256[] memory, uint256) {
        AllocationRecord[] storage records = userAllocationRecords[user];
        require(records.length > 0, "No allocation records found for user");
        
        // 使用两个数组来存储唯一质押地址和对应的总金额
        address[] memory tempAddresses = new address[](records.length);
        uint256[] memory tempAmounts = new uint256[](records.length);
        uint256 uniqueCount = 0;
        
        // 遍历所有分配记录
        for (uint256 i = 0; i < records.length; i++) {
            AllocationRecord storage record = records[i];
            // 检查节点是否活动
            uint256 nodeId = record.nodeId;
            uint256 nodeIndex = nodeIndexById[nodeId];
            if (nodeIndex >= deployNode.length || !deployNode[nodeIndex].isActive) {
                continue; // 跳过非活动节点的分配记录
            }
            
            address stakeAddress = record.stakeAddress;
            uint256 amount = record.amount;
            
            // 查找地址是否已经存在，使用早期返回优化
            bool found = false;
            uint256 j;
            for (j = 0; j < uniqueCount; j++) {
                if (tempAddresses[j] == stakeAddress) {
                    found = true;
                    break;
                }
            }
            
            if (found) {
                // 如果地址已存在，累加金额
                tempAmounts[j] += amount;
            } else {
                // 如果是新地址，添加到数组
                tempAddresses[uniqueCount] = stakeAddress;
                tempAmounts[uniqueCount] = amount;
                uniqueCount++;
            }
        }
        
        require(uniqueCount > 0, "No active node allocation records found for user");
        
        // 创建结果数组
        address[] memory stakeAddresses = new address[](uniqueCount);
        uint256[] memory equivalents = new uint256[](uniqueCount);
        uint256 totalEquivalent = 0;
        
        // 将临时数组转换为最终结果并计算总等效值
        for (uint256 i = 0; i < uniqueCount; i++) {
            uint256 totalAmount = tempAmounts[i];
            
            // 计算等效值：(分配金额 × 精度) / 100万
            uint256 equivalent = (totalAmount * SCALE) / DEFAULT_CAPACITY;
            
            stakeAddresses[i] = tempAddresses[i];
            equivalents[i] = equivalent;
            totalEquivalent += equivalent;
        }
        
        return (stakeAddresses, equivalents, totalEquivalent);
    }

    // ==================== 奖励分发功能 ====================

    /**
     * @dev 分发奖励给用户（只有管理员能调用）
     * @param _users 用户地址数组（最多50个）
     * 规则：1.每人每天只能领一次 2.奖励按等效值比例分配 3.50%给用户，50%给质押地址
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
            length > 0 && length <= 30,
            "Invalid users count"
        );

        // 获取当前奖励信息（从奖励计算器获取）
        (
            uint256 dailyReward,
            uint16 currentYear,
            uint256 currentDay
        ) = getCurrentRewardInfo();
        require(dailyReward > 0, "Daily reward is zero");

        // 计算有效总量（最少按500个节点算）
        uint256 effectiveTotal = totalPhysicalNodesEquivalent <
            (BASENODE * SCALE)
            ? (BASENODE * SCALE)
            : totalPhysicalNodesEquivalent;
        require(effectiveTotal > 0, "No physical nodes sold yet");

        // 合并计算奖励和分发奖励的循环
        uint256 totalDistributed = 0;
        uint256 usersProcessed = 0;
        uint256 totalRewardNeeded = 0;

        // 创建一个临时数组来存储用户奖励，用于后续余额检查
        uint256[] memory userRewards = new uint256[](length);

        // 第一遍循环：计算所有用户的奖励总额，用于余额检查
        for (uint256 i = 0; i < length; i++) {
            address user = _users[i];

            // 地址不为空
            require(user != address(0), "User address cannot be zero");

            // 检查今天是否已领取
            if (lastRewardDay[user][currentYear] >= currentDay) continue;

            uint256 userEquivalent = userPhysicalNodesEquivalent[user];
            if (userEquivalent == 0) continue;

            // 计算用户应得的每日奖励
            uint256 totalDailyReward = (dailyReward * userEquivalent) / effectiveTotal;
            if (totalDailyReward == 0) continue;

            userRewards[i] = totalDailyReward;
            totalRewardNeeded += totalDailyReward;
        }

        // 检查合约余额是否足够
        require(
            address(this).balance >= totalRewardNeeded,
            "Insufficient contract balance"
        );

        // 第二遍循环：实际分发奖励
        for (uint256 i = 0; i < length; i++) {
            if (userRewards[i] == 0) continue;

            address user = _users[i];
            // 从用户的分配记录中获取所有质押地址及其等效值和总等效值
            (address[] memory stakeAddresses, uint256[] memory equivalents, uint256 totalStakeEquivalent) = getStakeAddressesWithEquivalent(user);
            uint256 length2 = stakeAddresses.length;
            require(
                length2 > 0,
                "No stake addresses found for user"
            );

            // 计算分配金额：50%给用户，50%给质押地址
            uint256 userReward = userRewards[i] / 2;
            uint256 totalStakeReward = userRewards[i] - userReward;

            // 转账给用户
            TransferHelper.safeTransferETH(user, userReward);

            // 验证总等效值大于0
            require(totalStakeEquivalent > 0, "Total stake equivalent cannot be zero");

            // 分发奖励给质押地址
            for (uint256 j = 0; j < length2; j++) {
                address stakeAddress = stakeAddresses[j];
                require(stakeAddress != address(0), "Stake address cannot be zero");
                uint256 stakeEquivalent = equivalents[j];
                uint256 stakeReward = (totalStakeReward * stakeEquivalent) / totalStakeEquivalent;
                
                if (stakeReward > 0) {
                    TransferHelper.safeTransferETH(stakeAddress, stakeReward);
                    // 触发质押地址奖励分发事件
                    emit StakeRewardDistributed(
                        user,
                        stakeAddress,
                        stakeReward,
                        currentYear
                    );
                }
            }

            // 立即更新领取记录，防止同批次内重复地址领取
            lastRewardDay[user][currentYear] = currentDay;

            totalDistributed += userRewards[i];
            usersProcessed++;

            // 触发奖励分发事件
            emit RewardDistributed(
                user,
                userReward,
                currentYear
            );
        }

        // 触发批量奖励分发事件
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
    function addWithdrawSigner(address _signer) external onlyWithdrawMultiSig {
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
    function removeWithdrawSigner(address _signer) external onlyWithdrawMultiSig {
        require(isWithdrawSigner[_signer], "Not a signer");
        
        // 查找签名人索引
        uint256 index = type(uint256).max;
        for (uint i = 0; i < withdrawSigners.length; i++) {
            if (withdrawSigners[i] == _signer) {
                index = i;
                break;
            }
        }
        
        require(index != type(uint256).max, "Signer not found");
        
        // 移除签名人
        withdrawSigners[index] = withdrawSigners[withdrawSigners.length - 1];
        withdrawSigners.pop();
        delete isWithdrawSigner[_signer];
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
