module.exports = {
  skipFiles: [
    'test/',           // 测试文件
    'mock/',           // Mock合约
    'interfaces/',     // 接口文件
    'utils/',          // 工具库
  ],
  configureYulOptimizer: true,
  measureStatementCoverage: true,
  measureFunctionCoverage: true,
  measureBranchCoverage: true,
  mocha: {
    grep: '@skip-on-coverage', // 查找标记为跳过覆盖率的测试
    invert: true                // 反转匹配
  }
};
