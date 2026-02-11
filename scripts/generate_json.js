#!/usr/bin/env node
/**
 * 提取所有 standard_json 文件到 json/ 目录
 * 为每个合约生成只包含其依赖源文件的 standard_json
 * 使用方法: node scripts/generate_json.js
 */

const fs = require('fs');
const path = require('path');

const buildInfoDir = path.join(__dirname, '..', 'artifacts', 'build-info');
const outputDir = path.join(__dirname, '..', 'json');

/**
 * 确保目录存在
 */
function ensureDir(dir) {
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
}

/**
 * 安全写入文件
 */
function safeWriteFile(filePath, content) {
    try {
        fs.writeFileSync(filePath, content, 'utf8');
        return true;
    } catch (error) {
        console.error(`❌ 写入文件失败 ${filePath}: ${error.message}`);
        return false;
    }
}

/**
 * 从源代码中提取 import 语句
 */
function extractImports(sourceCode) {
    const imports = new Set();
    const importRegex = /import\s+(?:(?:"([^"]+)"|'([^']+)')|\{[^}]*\}\s+from\s+(?:"([^"]+)"|'([^']+)'))/g;
    
    let match;
    while ((match = importRegex.exec(sourceCode)) !== null) {
        const importPath = match[1] || match[2] || match[3] || match[4];
        if (importPath) {
            imports.add(importPath);
        }
    }
    
    return imports;
}

/**
 * 解析 import 路径为实际文件路径
 */
function resolveImportPath(importPath, currentFile, allSources) {
    // 如果是相对路径
    if (importPath.startsWith('./') || importPath.startsWith('../')) {
        const currentDir = path.dirname(currentFile);
        const resolved = path.normalize(path.join(currentDir, importPath)).replace(/\\/g, '/');
        
        // 尝试添加 .sol 扩展名
        if (allSources[resolved]) return resolved;
        if (allSources[resolved + '.sol']) return resolved + '.sol';
    }
    
    // 直接匹配（node_modules 或绝对路径）
    if (allSources[importPath]) return importPath;
    if (allSources[importPath + '.sol']) return importPath + '.sol';
    
    return null;
}

/**
 * 递归收集合约的所有依赖
 */
function collectDependencies(sourcePath, allSources, visited = new Set()) {
    if (visited.has(sourcePath)) return visited;
    
    visited.add(sourcePath);
    
    const sourceContent = allSources[sourcePath]?.content;
    if (!sourceContent) return visited;
    
    const imports = extractImports(sourceContent);
    
    for (const importPath of imports) {
        const resolvedPath = resolveImportPath(importPath, sourcePath, allSources);
        if (resolvedPath && !visited.has(resolvedPath)) {
            collectDependencies(resolvedPath, allSources, visited);
        }
    }
    
    return visited;
}

/**
 * 为合约创建过滤后的 standard_json
 */
function createFilteredStandardJson(contractSourcePath, buildInfo) {
    const allSources = buildInfo.input.sources;
    
    // 收集该合约的所有依赖
    const dependencies = collectDependencies(contractSourcePath, allSources);
    
    // 创建只包含相关源文件的新 input
    const filteredSources = {};
    for (const sourcePath of dependencies) {
        if (allSources[sourcePath]) {
            filteredSources[sourcePath] = allSources[sourcePath];
        }
    }
    
    // 创建新的 standard_json
    const filteredInput = {
        ...buildInfo.input,
        sources: filteredSources
    };
    
    return filteredInput;
}

/**
 * 主函数
 */
function main() {
    console.log(`📂 输出目录: ${outputDir}`);
    console.log(`📂 构建目录: ${buildInfoDir}\n`);

    // 检查构建目录
    if (!fs.existsSync(buildInfoDir)) {
        console.error('❌ artifacts/build-info 不存在，请先运行 npx hardhat compile');
        process.exit(1);
    }

    // 确保输出目录存在
    ensureDir(outputDir);

    // 读取所有 build-info 文件
    const files = fs.readdirSync(buildInfoDir).filter(f => f.endsWith('.json'));
    if (files.length === 0) {
        console.error('❌ 没有找到 build-info json 文件');
        process.exit(1);
    }

    // 存储每个合约的信息：{ contractName: { sourcePath, buildInfo } }
    const contractInfoMap = new Map();

    // 遍历所有 build-info 文件
    for (const file of files) {
        const filePath = path.join(buildInfoDir, file);
        
        try {
            const buildInfo = JSON.parse(fs.readFileSync(filePath, 'utf8'));

            // 验证必要字段
            if (!buildInfo.input || !buildInfo.output?.contracts) {
                continue;
            }

            // 提取所有合约及其源文件路径
            for (const [sourcePath, contracts] of Object.entries(buildInfo.output.contracts)) {
                for (const contractName of Object.keys(contracts)) {
                    // 只保存每个合约的第一个 build-info
                    if (!contractInfoMap.has(contractName)) {
                        contractInfoMap.set(contractName, {
                            sourcePath,
                            buildInfo
                        });
                    }
                }
            }
        } catch (error) {
            console.error(`⚠️  无法处理 ${file}: ${error.message}`);
        }
    }

    // 生成 standard_json 文件
    let successCount = 0;
    const contractNames = Array.from(contractInfoMap.keys()).sort();

    for (const contractName of contractNames) {
        const { sourcePath, buildInfo } = contractInfoMap.get(contractName);
        
        // 创建过滤后的 standard_json
        const filteredJson = createFilteredStandardJson(sourcePath, buildInfo);
        
        const fileName = `${contractName.toLowerCase()}_standard_json.json`;
        const outputPath = path.join(outputDir, fileName);

        if (safeWriteFile(outputPath, JSON.stringify(filteredJson, null, 2))) {
            const sourceCount = Object.keys(filteredJson.sources).length;
            console.log(`✅ ${fileName} (${sourceCount} 个源文件)`);
            successCount++;
        }
    }

    // 输出统计信息
    console.log(`\n✨ 完成！成功生成 ${successCount}/${contractNames.length} 个 standard_json 文件`);
    if (contractNames.length > 0) {
        console.log(`📋 包含的合约: ${contractNames.join(', ')}`);
    }
}

// 执行主函数
main();
