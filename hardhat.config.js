require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("solidity-coverage");
require("dotenv").config();
require("hardhat-contract-sizer");


// 配置hardhat accounts参数
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.0",
        settings: {
          optimizer: {
            enabled: true,
            runs: 2000
          },
          viaIR: true
        }
      },
      {
        version: "0.8.20", 
        settings: { 
          optimizer: { 
            enabled: true, 
            runs: 10000 
          }, 
            viaIR: true 
        }
      },
      {
        version: "0.6.6",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.6.2",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.5.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.5.16",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.5.0",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.4.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.4.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
    ]
  },
  networks: {
    mainnet: {
      url: process.env.MAINNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.MAINNET_CHIAN_ID)
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.SEPOLIA_CHAIAN_ID),
      // 增加超时时间，防止网络问题
      timeout: 120000, // 120秒
      gasPrice: "auto"
    },
    bscTestnet: {
      url: process.env.BSCTEST_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BSC_TESTNET_CHAIN_ID)
    },
    bsc: {
      url: process.env.BSCMAINNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BSC_MAINNET_CHAIN_ID)
    },
    local: {
      url: process.env.LOCAL_RPC_URL || "",
      accounts: process.env.LOCAL_PRIVATE_KEY !== undefined ? [process.env.LOCAL_PRIVATE_KEY] : []
    },
    monadTestnet: {
      url: process.env.MONAD_TESTNET_RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.MONAD_TESTNET_CHAIN_ID)
    },
    monadMainnet: {
      url: process.env.MONAD_MAINNET_RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.MONAD_MAINNET_CHAIN_ID)
    },
    beechain: {
      url: process.env.BEE_MAINNET_RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BEE_MAINNET_CHAIN_ID)
    },
    arbTestnet: {
      url: process.env.ARB_SEPOLIA_RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.ARB_SEPOLIA_CHAIN_ID)
    },
    baseTestnet: {
      url: process.env.BASE_SEPOLIA_RPC_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BASE_SEPOLIA_CHIAN_ID)
    },
  },
  etherscan: {
    enabled: true,
    // 使用新的 v2 API 配置
    apiKey: {
      monadMainnet: process.env.ETHERSCAN_API_KEY,
      monadTestnet: process.env.ETHERSCAN_API_KEY,
      bsc: process.env.BSCSCAN_API_KEY,
      bscTestnet: process.env.BSCSCAN_API_KEY,
      sepolia: process.env.ETHERSCAN_API_KEY,
      bee: process.env.BEECHAIN_API_KEY
    },
    customChains: [
      {
        network: "monadTestnet",
        chainId: parseInt(process.env.MONAD_TESTNET_CHAIN_ID),
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=10143",
          browserURL: "https://testnet.monadscan.com"
        }
      },
      {
        network: "monadMainnet",
        chainId: parseInt(process.env.MONAD_MAINNET_CHAIN_ID),
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=143",
          browserURL: "https://monadscan.com"
        }
      },
      {
        network: "bscTestnet",
        chainId: parseInt(process.env.BSC_TESTNET_CHAIN_ID),
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=97",
          browserURL: "https://testnet.bscscan.com"
        }
      },
      {
        network: "bsc",
        chainId: parseInt(process.env.BSC_MAINNET_CHAIN_ID),
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=56",
          browserURL: "https://bscscan.com"
        }
      },
      {
        network: "sepolia",
        chainId: parseInt(process.env.SEPOLIA_CHAIAN_ID),
        urls: {
          apiURL: "https://api-sepolia.etherscan.io/api",
          browserURL: "https://sepolia.etherscan.io"
        }
      },
      {
        network: "beechain",
        chainId: parseInt(process.env.BEE_MAINNET_CHAIN_ID),
        urls: {
          apiURL: "https://scan.beechain.ai/api",
          browserURL: "https://scan.beechain.ai"
        }
      }
    ]
  },
  // 覆盖率配置
  coverage: {
    enabled: true,
    exclude: ['test/', 'node_modules/', 'coverage/', 'scripts/'],
    reporter: ['html', 'lcov', 'text', 'json'],
    solcoverjs: './.solcover.js',
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS ? true : false,
    currency: 'USD',
    gasPrice: 20, // Gwei
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
    token: 'ETH',
    outputFile: 'gas-report.txt',
    noColors: true,
    // 排除一些测试文件
    excludeContracts: ['Test', 'Mock'],
  },
  mocha: {
    timeout: 40000
  },
  sourcify: {
    enabled: false,
    apiUrl: "https://sourcify.dev/server/",
    browserUrl: "https://sourcify.dev"
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};
