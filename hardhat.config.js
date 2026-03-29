require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("solidity-coverage");
require("dotenv").config();
require("hardhat-contract-sizer");

function getAccountsFromEnv(envKey) {
  const rawKey = process.env[envKey] || "";
  if (!rawKey) return [];
  const normalized = rawKey.startsWith("0x") ? rawKey : `0x${rawKey}`;
  if (normalized.length !== 66) return [];
  return [normalized];
}

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
    /** overrides 的具体作用
    * optimizer.runs: 1：优先减小 bytecode（牺牲部分运行时 gas）
    * viaIR: true：很多复杂合约能进一步压缩体积
    * metadata.bytecodeHash: "none"：去掉元数据哈希，减少字节码长度
    * debug.revertStrings: "strip"：移除 revert 字符串，显著减小体积（但测试里就拿不到 reason 文本）
    */
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
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.MAINNET_CHIAN_ID) || 1
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.SEPOLIA_CHAIN_ID) || 11155111,
      timeout: 120000,
      gasPrice: "auto"
    },
    bscTestnet: {
      url: process.env.BSC_TESTNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.BSC_TESTNET_CHAIN_ID) || 97
    },
    bsc: {
      url: process.env.BSC_MAINNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.BSC_MAINNET_CHAIN_ID) || 56
    },
    local: {
      url: process.env.LOCAL_RPC_URL || "",
      accounts: getAccountsFromEnv("LOCAL_PRIVATE_KEY")
    },
    monadTestnet: {
      url: process.env.MONAD_TESTNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.MONAD_TESTNET_CHAIN_ID) || 0
    },
    monadMainnet: {
      url: process.env.MONAD_MAINNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.MONAD_MAINNET_CHAIN_ID) || 0
    },
    beechainMainnet: {
      url: process.env.BEE_MAINNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.BEE_MAINNET_CHAIN_ID) || 0
    },
    arbitrumSepolia: {
      url: process.env.ARB_SEPOLIA_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.ARB_SEPOLIA_CHAIN_ID) || 0
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.BASE_SEPOLIA_CHIAN_ID) || 0
    },
    moonbaseAlphaTestnet: {
      url: process.env.MOONBASE_ALPHA_TESTNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.MOONBASE_ALPHA_TESTNET_CHAIN_ID) || 0
    },
    moonbeamMainnet: {
      url: process.env.MOONBEAM_MAINNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.MOONBEAM_MAINNET_CHAIN_ID) || 0
    },
    polkadotTestnet: {
      url: process.env.POLKADOT_TESTNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.POLKADOT_TESTNET_CHAIN_ID) || 420420417,
    },
    polkadotMainnet: {
      url: process.env.POLKADOT_MAINNET_RPC_URL || "",
      accounts: getAccountsFromEnv("PRIVATE_KEY"),
      chainId: parseInt(process.env.POLKADOT_MAINNET_CHAIN_ID) || 420420419,
    }
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
      baseSepolia: process.env.ETHERSCAN_API_KEY,
      moonbaseAlphaTestnet: process.env.ETHERSCAN_API_KEY,
      moonbeamMainnet: process.env.ETHERSCAN_API_KEY,
      polkadotTestnet: process.env.POLKADOTETHERSCAN_API_KEY,
      polkadotMainnet: process.env.POLKADOTETHERSCAN_API_KEY
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
      },
      {
        network: "moonbaseAlphaTestnet",
        chainId: parseInt(process.env.MOONBASE_ALPHA_TESTNET_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.MOONBASE_ALPHA_TESTNET_CHAIN_ID)}`,
          browserURL: process.env.MOONBASE_ALPHA_TESTNET_ETHERSCAN_URL
        }
      },
      {
        network: "moonbeamMainnet",
        chainId: parseInt(process.env.MOONBEAM_MAINNET_CHAIN_ID),
        urls: {
          apiURL: `https://api.etherscan.io/v2/api?chainid=${parseInt(process.env.MOONBEAM_MAINNET_CHAIN_ID)}`,
          browserURL: process.env.MOONBEAM_MAINNET_ETHERSCAN_URL
        }
      },
      {
        network: 'polkadotTestnet',
        chainId: parseInt(process.env.POLKADOT_TESTNET_CHAIN_ID),
        urls: {
          apiURL: process.env.POLKADOT_TESTNET_BLOCKSCOUT_API_URL,
          browserURL: process.env.POLKADOT_TESTNET_ETHERSCAN_URL
        },
      },
      {
        network: 'polkadotMainnet',
        chainId: parseInt(process.env.POLKADOT_MAINNET_CHAIN_ID),
        urls: {
          apiURL: process.env.POLKADOT_MAINNET_BLOCKSCOUT_API_URL,
          browserURL: process.env.POLKADOT_MAINNET_ETHERSCAN_URL
        },
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
