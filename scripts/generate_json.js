#!/usr/bin/env node
/**
 * 提取所有 standard_json 文件到 json/ 目录
 * 使用方法: node scripts/generate_json.js
 */

const fs = require('fs');
const path = require('path');

const buildInfoDir = path.join(__dirname, '..', 'artifacts', 'build-info');
const outputDir = path.join(__dirname, '..', 'json');

// 确保输出目录存在
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

console.log(`📂 输出目录: ${outputDir}`);
console.log(`📂 构建目录: ${buildInfoDir}\n`);

if (!fs.existsSync(buildInfoDir)) {
    console.error('❌ artifacts/build-info 不存在，请先运行 npx hardhat compile');
    process.exit(1);
}

const files = fs.readdirSync(buildInfoDir).filter(f => f.endsWith('.json'));
if (files.length === 0) {
    console.error('❌ 没有找到 build-info json 文件');
    process.exit(1);
}

let count = 0;
const contracts = new Set();

for (const file of files) {
    const p = path.join(buildInfoDir, file);
    try {
        const bi = JSON.parse(fs.readFileSync(p, 'utf8'));

        if (!bi.input || !bi.output || !bi.output.contracts) continue;

        for (const [sourcePath, contractMap] of Object.entries(bi.output.contracts)) {
            for (const [contractName, def] of Object.entries(contractMap)) {
                contracts.add(contractName);

                const outNameBase = `${contractName.toLowerCase()}_standard_json`;
                let outName = `${outNameBase}.json`;
                let counter = 1;

                // 避免覆盖已存在的文件（添加计数器）
                while (fs.existsSync(path.join(outputDir, outName))) {
                    outName = `${outNameBase}_${counter}.json`;
                    counter++;
                }

                const outPath = path.join(outputDir, outName);
                fs.writeFileSync(outPath, JSON.stringify(bi.input, null, 2));

                console.log(`✅ ${outName}`);
                count++;
            }
        }
    } catch (e) {
        console.error(`⚠️  无法处理 ${file}: ${e.message}`);
    }
}

console.log(`\n✨ 完成！生成了 ${count} 个 standard_json 文件`);
console.log(`📋 包含的合约: ${Array.from(contracts).sort().join(', ')}`);
