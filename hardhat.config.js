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
        version: "0.8.22",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1
          },
          viaIR: true,
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1
          },
          viaIR: true,
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
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
            runs: 1
          },
          viaIR: true,
          metadata: {
            bytecodeHash: "none"
          }
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
    ],
    overrides: {
      "contracts/ServerNodeV2Backup.sol": {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1
          },
          viaIR: true,
          metadata: {
            bytecodeHash: "none"
          },
          debug: {
            revertStrings: "strip"
          }
        }
      }
    }
  },
  networks: {
    hardhat: {
      chainId: 31337
    },
    mainnet: {
      url: process.env.MAINNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.MAINNET_CHIAN_ID) || 1
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.SEPOLIA_CHAIN_ID) || 11155111,
      timeout: 120000,
      gasPrice: "auto"
    },
    bscTestnet: {
      url: process.env.BSC_TESTNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BSC_TESTNET_CHAIN_ID) || 97
    },
    bsc: {
      url: process.env.BSC_MAINNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BSC_MAINNET_CHAIN_ID) || 56
    },
    local: {
      url: process.env.LOCAL_RPC_URL || "",
      accounts: process.env.LOCAL_PRIVATE_KEY && process.env.LOCAL_PRIVATE_KEY.length === 66 ? [process.env.LOCAL_PRIVATE_KEY] : []
    },
    monadTestnet: {
      url: process.env.MONAD_TESTNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.MONAD_TESTNET_CHAIN_ID) || 0
    },
    monadMainnet: {
      url: process.env.MONAD_MAINNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.MONAD_MAINNET_CHAIN_ID) || 0
    },
    beechainMainnet: {
      url: process.env.BEE_MAINNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BEE_MAINNET_CHAIN_ID) || 0
    },
    arbitrumSepolia: {
      url: process.env.ARB_SEPOLIA_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.ARB_SEPOLIA_CHAIN_ID) || 0
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY && process.env.PRIVATE_KEY.length === 66 ? [process.env.PRIVATE_KEY] : [],
      chainId: parseInt(process.env.BASE_SEPOLIA_CHIAN_ID) || 0
    },
  },
  etherscan: {
    enabled: true,
    // 使用新的 v2 API 配置
    apiKey: {
      monadMainnet: process.env.ETHERSCAN_API_KEY,
      monadTestnet: process.env.ETHERSCAN_API_KEY,
      bsc: process.env.BSC_SCAN_BACKUP_API_KEY,
      bscTestnet: process.env.BSC_SCAN_BACKUP_API_KEY,
      sepolia: process.env.ETHERSCAN_API_KEY,
      beechainMainnet: process.env.BEECHAIN_API_KEY,
      arbitrumSepolia: process.env.ETHERSCAN_API_KEY,
      baseSepolia: process.env.ETHERSCAN_API_KEY
    },
    customChains: [
      {
        network: "monadTestnet",
        chainId: parseInt(process.env.MONAD_TESTNET_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.MONAD_TESTNET_CHAIN_ID)}`,
          browserURL: process.env.MONAD_TESTNET_ETHERSCAN_URL
        }
      },
      {
        network: "monadMainnet",
        chainId: parseInt(process.env.MONAD_MAINNET_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.MONAD_MAINNET_CHAIN_ID)}`,
          browserURL: process.env.MONAD_MAINNET_ETHERSCAN_URL
        }
      },
      {
        network: "bscTestnet",
        chainId: parseInt(process.env.BSC_TESTNET_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.BSC_TESTNET_CHAIN_ID)}`,
          browserURL: process.env.BSC_TESTNET_ETHERSCAN_URL
        }
      },
      {
        network: "bsc",
        chainId: parseInt(process.env.BSC_MAINNET_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.BSC_MAINNET_CHAIN_ID)}`,
          browserURL: process.env.BSC_MAINNET_ETHERSCAN_URL
        }
      },
      {
        network: "sepolia",
        chainId: parseInt(process.env.SEPOLIA_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.SEPOLIA_CHAIN_ID)}`,
          browserURL: process.env.SEPOLIA_ETHERSCAN_URL
        }
      },
      {
        network: "beechainMainnet",
        chainId: parseInt(process.env.BEE_MAINNET_CHAIN_ID),
        urls: {
          apiURL: process.env.BEECHAIN_API_URL,
          browserURL: process.env.BEECHAIN_ETHERSCAN_URL
        }
      },
      {
        network: "arbitrumSepolia",
        chainId: parseInt(process.env.ARB_SEPOLIA_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.ARB_SEPOLIA_CHAIN_ID)}`,
          browserURL: process.env.ARB_SEPOLIA_ETHERSCAN_URL
        }
      },
      {
        network: "baseSepolia",
        chainId: parseInt(process.env.BASE_SEPOLIA_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.BASE_SEPOLIA_CHAIN_ID)}`,
          browserURL: process.env.BASE_SEPOLIA_ETHERSCAN_URL
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
