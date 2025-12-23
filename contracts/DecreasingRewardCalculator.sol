// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract DecreasingRewardCalculator {
    // 合约部署时间戳（秒）
    uint256 public immutable deploymentTimestamp;
    
    // 初始每日奖励基数 (BKC)
    uint256 public constant INITIAL_DAILY_REWARD = 50_000 * 1e18; // 假设 BKC 有 18 位小数
    
    // 递减率 (10%)
    uint256 public constant DECREASE_RATE = 10; // 百分比
    
    // 递减总年数
    uint256 public constant DECREASE_YEARS = 30;
    
    // 事件：奖励查询
    event RewardQueried(uint256 queryDay, uint256 dailyReward, uint256 year);
    
    constructor() {
        deploymentTimestamp = block.timestamp;
    }
    
    /**
     * @dev 计算指定天数（从部署日算起）的每日奖励
     * @param daysFromDeployment 从部署日开始的天数（1-based）
     * @return dailyReward 该日的每日奖励基数（BKC，带18位小数）
     */
    function getDailyReward(uint256 daysFromDeployment) public returns (uint256 dailyReward) {
        require(daysFromDeployment > 0, "Day must be positive");
        
        // 计算年数（1-based）
        uint256 year = ((daysFromDeployment - 1) / 365) + 1;
        
        // 第31年及以后使用第30年的值
        if (year > DECREASE_YEARS) {
            year = DECREASE_YEARS;
        }
        
        // 计算该年的每日奖励
        dailyReward = _calculateYearlyReward(year);
        
        emit RewardQueried(daysFromDeployment, dailyReward, year);
        return dailyReward;
    }
    
    /**
     * @dev 根据当前区块时间戳计算今日的奖励
     * @return dailyReward 今日的每日奖励基数
     * @return currentDay 从部署日开始计算的天数
     */
    function getCurrentDailyReward() public returns (uint256 dailyReward, uint256 currentDay) {
        currentDay = getDaysSinceDeployment();
        dailyReward = getDailyReward(currentDay);
        return (dailyReward, currentDay);
    }
    
    /**
     * @dev 获取从部署日到当前区块时间的天数
     * @return days 天数（1-based）
     */
    function getDaysSinceDeployment() public view returns (uint256) {
        uint256 secondsSinceDeployment = block.timestamp - deploymentTimestamp;
        uint256 daysSinceDeployment = secondsSinceDeployment / 86400; // 86400秒 = 1天
        
        // 如果不满一天，按一天算
        if (secondsSinceDeployment % 86400 > 0) {
            daysSinceDeployment += 1;
        }
        
        // 确保至少返回第1天
        return daysSinceDeployment > 0 ? daysSinceDeployment : 1;
    }
    
    /**
     * @dev 计算指定年份的每日奖励
     * @param year 年份（1-based）
     * @return 该年份的每日奖励
     */
    function _calculateYearlyReward(uint256 year) internal pure returns (uint256) {
        // 第一年：全额奖励
        if (year == 1) {
            return INITIAL_DAILY_REWARD;
        }
        
        // 计算递减次数
        uint256 decreaseCount = year - 1;
        
        // 计算公式：初始奖励 × (0.9)^(year-1)
        // 使用定点数学运算以避免浮点数
        
        uint256 reward = INITIAL_DAILY_REWARD;
        
        // 循环应用递减（对于30年来说Gas成本可接受）
        for (uint256 i = 0; i < decreaseCount; i++) {
            reward = (reward * (100 - DECREASE_RATE)) / 100;
        }
        
        return reward;
    }
    
    /**
     * @dev 获取特定年份的奖励信息（视图函数，无Gas成本）
     * @param year 年份（1-based）
     * @return dailyReward 该年份的每日奖励基数
     * @return isFixed 该年份是否已固定（第31年及以后）
     */
    function getYearlyRewardInfo(uint256 year) public pure returns (
        uint256 dailyReward, 
        bool isFixed
    ) {
        require(year > 0, "Year must be positive");
        
        isFixed = (year > DECREASE_YEARS);
        uint256 actualYear = isFixed ? DECREASE_YEARS : year;
        dailyReward = _calculateYearlyReward(actualYear);
        
        return (dailyReward, isFixed);
    }
    
    /**
     * @dev 批量计算多天的奖励（优化Gas使用）
     * @param startDay 起始天数
     * @param count 计算天数
     * @return rewards 每日奖励数组
     */
    function getBatchDailyRewards(
        uint256 startDay, 
        uint256 count
    ) public returns (uint256[] memory rewards) {
        require(startDay > 0 && count > 0, "Invalid parameters");
        
        rewards = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            rewards[i] = getDailyReward(startDay + i);
        }
        
        return rewards;
    }
}