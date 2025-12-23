// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

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

    function decrement(Counter storage counter) internal {
        uint256 value = counter._value;
        require(value > 0, "Counter: decrement overflow");
        unchecked {
            counter._value = value - 1;
        }
    }

    function reset(Counter storage counter) internal {
        counter._value = 0;
    }
}

contract ServerNode is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    uint256 public constant BIGNODE = 2000;
    uint256 public constant BASENODE = 500;
   
    using Counters for Counters.Counter;
    Counters.Counter private _counter;

    address public constant BKC = 0x8f97cd236fA90b66DdFC5410Dec8eFF0df527F2b; // 需要修改为实际地址
    address public REWARD;

    uint256 public totalPhysicalNodes;
    uint256 public totalNodesSold; // 总已售节点数量（按物理节点计算）

    struct NodeInfo {
        string ip;
        string describe;
        string name;
        bool isActive;
        uint8 typeParam;
        uint256 id;
        uint256 capacity;
        uint256 createTime;
        uint256 blockHeight;
    }

    struct configNodeParams {
        address stakeAddress;
        bool isActive;
        uint8 typeParam;
        uint256 id;
        uint256 nodeCapacity;
        uint256 nodeMoney;
        uint256 createTime;
        uint256 blockHeight;
    }

    mapping(address => bool) public whiteList;
    mapping(address => configNodeParams[]) public buyNode;
    mapping(uint256 => configNodeParams[]) public getBuyNodeById;
    mapping(address => NodeInfo[]) public deployNode;
    mapping(address => uint256) public userPhysicalNodes;

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "Only EOA");
        _;
    }

    event CreateNodeInfo(string indexed ip, string describe, string indexed name, bool isActive, uint8 typeParam, uint256 id, uint256 indexed capacity, uint256 blockTime, uint256 blockHeight);
    event ConfigNodeInfo(address indexed stakeAddress, bool isActive, uint8 typeParam, uint256 id, uint256 indexed capacity, uint256 money, uint256 blockTime, uint256 blockHeight);
    event RewardDistributed(address indexed user, uint256 indexed amount);
    event RewardPaused(address indexed admin);
    event RewardUnpaused(address indexed admin);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _rewardCalculator) public initializer {
        __Ownable_init(msg.sender);
        transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        REWARD = _rewardCalculator;
    }

     // 管理员创建节点
    function createNode(NodeInfo[] calldata _nodeInfo) public onlyOwner {
        _counter.increment();
        uint256 length = _nodeInfo.length;
        require(length > 0, "Node information cannot be an empty array.");
        for(uint256 i = 0; i < length; i++){
            deployNode[_msgSender()].push(NodeInfo({
               ip: _nodeInfo[i].ip,
               describe: _nodeInfo[i].describe,
               name: _nodeInfo[i].name,
               isActive: _nodeInfo[i].isActive,
               typeParam: _nodeInfo[i].typeParam,
               id: _counter.current(),
               capacity: _nodeInfo[i].capacity,
               createTime: block.timestamp,
               blockHeight: block.number
            }));

            emit CreateNodeInfo(_nodeInfo[i].ip, _nodeInfo[i].describe, _nodeInfo[i].name, _nodeInfo[i].isActive, _nodeInfo[i].typeParam, _counter.current(), _nodeInfo[i].capacity, block.timestamp, block.number);
        }
    }

    // 配置节点信息 - 当合约暂停时，此功能仍可继续（仅奖励分配暂停）
    function configNode(configNodeParams[] calldata _buyNodeInfo) public nonReentrant {
        address from = _msgSender();
        require(owner() == from || whiteList[from], "Only whitelist or Only Owner");
        uint256 length = _buyNodeInfo.length;
        require(length > 0, "Node information cannot be an empty array.");

        uint256 physicalNodesToAdd = 0;

        for(uint256 i = 0; i < length; i++){
            uint8 nodeType = _buyNodeInfo[i].typeParam;
            uint256 nodeValue = _buyNodeInfo[i].nodeMoney;
            uint256 physicalNodeCount = 0;

            // 根据节点类型计算物理节点数量
            if (nodeType == 1) { // 大节点
                physicalNodeCount = 1;
            } else if (nodeType == 2) { // 中节点 (5个中节点=1物理节点)
                physicalNodeCount = 1;
            } else if (nodeType == 3) { // 小节点 (20个小节点=1物理节点)
                physicalNodeCount = 1;
            } else if (nodeType == 4) { // 商品节点
                physicalNodeCount = nodeValue / 1000000;
                if (nodeValue % 1000000 > 0) {
                    physicalNodeCount += 1;
                }
            }

            // 对于中节点和小节点，需要根据实际数量折算
            if (nodeType == 2) { // 中节点
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 5;
            } else if (nodeType == 3) { // 小节点
                physicalNodeCount = _buyNodeInfo[i].nodeCapacity / 20;
            }

            physicalNodesToAdd += physicalNodeCount;

            buyNode[from].push(configNodeParams({
                stakeAddress: from,
                isActive: _buyNodeInfo[i].isActive,
                typeParam: nodeType,
                id: _buyNodeInfo[i].id,
                nodeCapacity: _buyNodeInfo[i].nodeCapacity,
                nodeMoney: nodeValue,
                createTime: block.timestamp,
                blockHeight: block.number
            }));

            getBuyNodeById[_buyNodeInfo[i].id].push(configNodeParams({
                stakeAddress: from,
                isActive: _buyNodeInfo[i].isActive,
                typeParam: nodeType,
                id: _buyNodeInfo[i].id,
                nodeCapacity: _buyNodeInfo[i].nodeCapacity,
                nodeMoney: nodeValue,
                createTime: block.timestamp,
                blockHeight: block.number
            }));

            emit ConfigNodeInfo(from, _buyNodeInfo[i].isActive, nodeType, _buyNodeInfo[i].id, _buyNodeInfo[i].nodeCapacity, nodeValue, block.timestamp, block.number);
        }

        require(totalPhysicalNodes + physicalNodesToAdd <= BIGNODE, "Exceeds maximum physical nodes limit");

        totalPhysicalNodes += physicalNodesToAdd;
        userPhysicalNodes[from] += physicalNodesToAdd;
        totalNodesSold += physicalNodesToAdd;
    }

    // 配置白名单
    function setWhiteList(address user, bool _isTrue) external onlyOwner {
        whiteList[user] = _isTrue;
    }

    // 管理员充值BKC
    function depositToken(uint256 amount) external onlyOwner {
        require(amount > 0, "amount must be than 0");
        require(IERC20(BKC).allowance(owner(), address(this)) >= amount, "BKC allowance not sufficient");
        TransferHelper.safeTransferFrom(BKC, msg.sender, address(this), amount);
    }

    // 查询合约内的BKC
    function getTokenBalance() external view returns(uint256) {
        return IERC20(BKC).balanceOf(address(this));
    }

    // 根据节点id查询配置记录
    function getConfigNodeInfo(address user, uint256 startId, uint256 endId) external view returns(configNodeParams[] memory) {
        require(user != address(0), "Invalid user address");
        require(startId != 0 && endId != 0, "Invalid ID range");
        require(startId <= endId, "Start ID must be less than or equal to end ID");

        configNodeParams[] storage userNodes = buyNode[user];
        uint256 nodeCount = userNodes.length;

        if (nodeCount == 0) {
            return new configNodeParams[](0);
        }

        uint256 matchCount = 0;
        for (uint256 i = 0; i < nodeCount; i++) {
            uint256 nodeId = userNodes[i].id;
            if (nodeId >= startId && nodeId <= endId) {
                matchCount++;
            }
        }

        configNodeParams[] memory result = new configNodeParams[](matchCount);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < nodeCount; i++) {
            uint256 nodeId = userNodes[i].id;
            if (nodeId >= startId && nodeId <= endId) {
                result[resultIndex] = userNodes[i];
                resultIndex++;
            }
        }

        return result;
    }

    // 查询每日奖励统计
    function getDailyRewards(uint8 _year) internal view returns(uint256) {
        (bool success, bytes memory data) = REWARD.staticcall(abi.encodeWithSignature("getYearlyRewardInfo(uint256)", _year));
        require(success && data.length > 0, "Query quantity failed");
        (uint256 amount, ) = abi.decode(data, (uint256,bool));
        return amount;
    }

    // 分配每日奖励 - 使用 whenNotPaused 修饰符
    function configRewards(address user, uint8 _year) external onlyOwner whenNotPaused {
        require(user != address(0), "Invalid user address");

        uint256 userPhysicalNodeCount = userPhysicalNodes[user];
        require(userPhysicalNodeCount > 0, "User has no physical nodes");

        uint256 totalPhysicalNodeCount = totalNodesSold;

        // 计算有效物理节点总数
        uint256 effectiveTotalNodes = totalPhysicalNodeCount <= BASENODE ? BASENODE : totalPhysicalNodeCount;

        // 获取奖励
        uint256 reward = getDailyRewards(_year);

        // 先乘后除，避免整数除法精度损失
        uint256 rewardAmount = (reward * userPhysicalNodeCount) / effectiveTotalNodes;

        require(rewardAmount > 0, "Reward amount too small");

        require(IERC20(BKC).balanceOf(address(this)) >= rewardAmount, "Insufficient reward balance");
        TransferHelper.safeTransfer(BKC, user, rewardAmount);

        emit RewardDistributed(user, rewardAmount);
    }

    // 暂停奖励分配（管理员专用）
    function pauseRewards() external onlyOwner {
        _pause();
        emit RewardPaused(msg.sender);
    }

    // 恢复奖励分配（管理员专用）
    function unpauseRewards() external onlyOwner {
        _unpause();
        emit RewardUnpaused(msg.sender);
    }

    // 可选：添加查询暂停状态函数
    function isPaused() external view returns (bool) {
        return paused();
    }


}
