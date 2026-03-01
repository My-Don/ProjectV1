// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract DecreasingRewardCalculator {
    // 合约部署时间戳（秒）
    uint256 public immutable deploymentTimestamp;

    // 初始每日奖励基数 (wei)
    // 注意：此常量仅用于参考，实际奖励值从 YEARLY_REWARDS 数组获取
    uint256 public constant INITIAL_DAILY_REWARD_WEI = 1 ether;

    // 递减率 (10%)
    uint256 public constant DECREASE_RATE = 10; // 百分比

    // 递减总年数
    uint256 public constant DECREASE_YEARS = 30;

    // 预计算的每年每日奖励值 (wei)
    // 使用查表法避免循环计算和精度损失
    uint256[30] private YEARLY_REWARDS = [
        1000000000000000000, // Year 1
        900000000000000000, // Year 2
        810000000000000000, // Year 3
        729000000000000000, // Year 4
        656100000000000000, // Year 5
        590490000000000000, // Year 6
        531441000000000000, // Year 7
        478296900000000000, // Year 8
        430467210000000000, // Year 9
        387420489000000000, // Year 10
        348678440100000000, // Year 11
        313810596090000000, // Year 12
        282429536481000000, // Year 13
        254186582832900000, // Year 14
        228767924549610000, // Year 15
        205891132094649000, // Year 16
        185302018885184100, // Year 17
        166771816996665690, // Year 18
        150094635296999121, // Year 19
        135085171767299208, // Year 20
        121576654590569287, // Year 21
        109418989131512358, // Year 22
        98477090218361122, // Year 23
        88629381196525009, // Year 24
        79766443076872508, // Year 25
        71789798769185257, // Year 26
        64610818892266731, // Year 27
        58149737003040057, // Year 28
        52334763302736051, // Year 29
        47101286972462445 // Year 30
    ];

    constructor() {
        deploymentTimestamp = block.timestamp;
    }

    /**
     * @dev 计算指定天数（从部署日算起）的每日奖励
     * @param daysFromDeployment 从部署日开始的天数（1-based）
     * @return dailyReward 该日的每日奖励基数（BKC，带18位小数）
     */
    function getDailyReward(
        uint256 daysFromDeployment
    ) public view returns (uint256 dailyReward) {
        require(daysFromDeployment > 0, "Day must be positive");

        // 计算年数（1-based）
        uint256 year = ((daysFromDeployment - 1) / 365) + 1;

        // 第31年及以后永久使用第30年的奖励值（不再递减），
        // 这是有意的设计：30年后奖励维持在约 0.042 ETH/天 的水平永久运行。
        // 注意：由于每次整除存在截断误差，第30年实际值与理论值（1e18 × 0.9^29）
        // 存在约 1~3% 的偏差，属于可接受范围。
        if (year > DECREASE_YEARS) {
            year = DECREASE_YEARS;
        }

        // 计算该年的每日奖励
        dailyReward = _calculateYearlyReward(year);

        return dailyReward;
    }

    /**
     * @dev 根据当前区块时间戳计算今日的奖励
     * @return dailyReward 今日的每日奖励基数
     * @return currentDay 从部署日开始计算的天数
     */
    function getCurrentDailyReward()
        public
        view
        returns (uint256 dailyReward, uint256 currentDay)
    {
        currentDay = getDaysSinceDeployment();
        dailyReward = getDailyReward(currentDay);
        return (dailyReward, currentDay);
    }

    /**
     * @dev 获取从部署日到当前区块时间的天数
     * @return days 天数（1-based）
     * 
     * 计算逻辑：
     * - 部署时刻 (secondsSinceDeployment = 0): 返回第 1 天
     * - 第 1 天期间 [0, 86400): 返回第 1 天
     * - 第 2 天开始 (secondsSinceDeployment >= 86400): 返回第 2 天
     * - 以此类推
     * 
     * 公式：(已过去的完整天数) + 1 = 当前天数
     */
    function getDaysSinceDeployment() public view returns (uint256) {
        uint256 secondsSinceDeployment = block.timestamp - deploymentTimestamp;
        return (secondsSinceDeployment / 86400) + 1;
    }

    /**
     * @dev 计算指定年份的每日奖励（使用查表法，O(1)复杂度，零精度损失）
     * @param year 年份（1-based）
     * @return 该年份的每日奖励
     */
    function _calculateYearlyReward(
        uint256 year
    ) internal view returns (uint256) {
        require(year > 0 && year <= DECREASE_YEARS, "Invalid year");
        // 使用查表法直接返回预计算值，避免循环和精度损失
        return YEARLY_REWARDS[year - 1];
    }

    /**
     * @dev 获取特定年份的奖励信息（视图函数，无Gas成本）
     * @param year 年份（1-based）
     * @return dailyReward 该年份的每日奖励基数
     * @return isFixed 该年份是否已固定（第31年及以后）
     */
    function getYearlyRewardInfo(
        uint256 year
    ) public view returns (uint256 dailyReward, bool isFixed) {
        require(year > 0, "Year must be positive");

        isFixed = (year > DECREASE_YEARS);
        uint256 actualYear = isFixed ? DECREASE_YEARS : year;
        dailyReward = _calculateYearlyReward(actualYear);

        return (dailyReward, isFixed);
    }

    /**
     * @dev 批量计算多天的奖励（优化Gas使用）
     * @param startDay 起始天数
     * @param count 计算天数（最多365天，防止 out-of-gas）
     * @return rewards 每日奖励数组
     */
    function getBatchDailyRewards(
        uint256 startDay,
        uint256 count
    ) public view returns (uint256[] memory rewards) {
        require(startDay > 0 && count > 0, "Invalid parameters");
        require(count <= 365, "Count exceeds maximum (365)");

        // 防止 startDay + count 溢出
        require(
            startDay <= type(uint256).max - count + 1,
            "Start day too large"
        );

        rewards = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            rewards[i] = getDailyReward(startDay + i);
        }

        return rewards;
    }

    /**
     * @dev 获取从部署日起当前处于第几年（1-based）
     * @return year 当前年份；超过 DECREASE_YEARS 后返回实际年份（奖励已固定不再递减）
     */
    function getCurrentYear() public view returns (uint256 year) {
        uint256 currentDay = getDaysSinceDeployment();
        year = ((currentDay - 1) / 365) + 1;
    }

    /**
     * @dev 获取距奖励递减结束还剩多少年
     * @return remaining 剩余递减年数；已过递减期则返回 0
     */
    function getRemainingDecreaseYears() public view returns (uint256 remaining) {
        uint256 year = getCurrentYear();
        if (year >= DECREASE_YEARS) {
            return 0;
        }
        remaining = DECREASE_YEARS - year;
    }
}
