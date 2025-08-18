#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const https = require('https');
const url = require('url');
const { execSync } = require('child_process');

// Config
const DEFAULT_OUTPUT_PREFIX = 'unpacked';
const DEPENDENCY_MANIFEST_PATTERNS = [
    /bender/i,
    /dependencies?/i,
    /manifest/i,
    /components?/i,
    /modules?/i
];

async function main() {
    try {
        const jsFile = process.argv[2];
        if (!jsFile) throw new Error('Please provide a JavaScript file path');
        
        // Create output directory
        const jsName = path.basename(jsFile, path.extname(jsFile));
        const outputDir = `${DEFAULT_OUTPUT_PREFIX}-${jsName}`;
        fs.mkdirSync(outputDir, { recursive: true });
        
        console.log(`🔍 Analyzing: ${jsFile}`);
        console.log(`📁 Output: ${outputDir}`);
        
        // Step 1: Extract source map URL
        const sourceMapUrl = extractSourceMapUrl(jsFile);
        if (!sourceMapUrl) throw new Error('No sourceMappingURL found');
        console.log(`🗺️ Source map: ${sourceMapUrl}`);
        
        // Step 2: Download source map
        const mapFilename = generateFilenameFromUrl(sourceMapUrl);
        const mapFile = path.join(outputDir, mapFilename);
        await downloadFile(sourceMapUrl, mapFile);
        console.log(`💾 Saved source map: ${mapFilename}`);
        
        // Step 3: Extract source files
        const manifestFiles = await extractSourceFiles(mapFile, outputDir);
        console.log(`✅ Extracted ${manifestFiles.fileCount} files`);
        
        // Step 4: Detect dependency manifests
        if (manifestFiles.manifestPaths.length > 0) {
            console.log('\n📦 Found dependency manifests:');
            manifestFiles.manifestPaths.forEach(p => console.log(`  - ${p}`));
            console.log('\n💡 Run the dependency downloader:');
            console.log(`   node dep-downloader.js ${outputDir}`);
        }
        
        console.log('\n🚀 Extraction complete! Ready for security research:');
        console.log(`   code ${outputDir}`);
    } catch (error) {
        console.error('❌ Error:', error.message);
        process.exit(1);
    }
}

// --- Utility Functions ---
function extractSourceMapUrl(filePath) {
    const content = fs.readFileSync(filePath, 'utf8');
    const regex = /\/\/# sourceMappingURL=([^\s]+)/;
    const match = content.match(regex);
    return match ? match[1].trim() : null;
}

function generateFilenameFromUrl(rawUrl) {
    const parsed = new URL(rawUrl.startsWith('//') ? `https:${rawUrl}` : rawUrl);
    return parsed.pathname
        .split('/')
        .filter(Boolean)
        .join('_')
        .replace(/[^a-z0-9_.-]/gi, '_');
}

async function downloadFile(rawUrl, outputPath) {
    return new Promise((resolve, reject) => {
        const parsedUrl = new URL(rawUrl.startsWith('//') ? `https:${rawUrl}` : rawUrl);
        const req = https.get(parsedUrl, (res) => {
            if (res.statusCode === 302 && res.headers.location) {
                return downloadFile(res.headers.location, outputPath).then(resolve).catch(reject);
            }
            
            const file = fs.createWriteStream(outputPath);
            res.pipe(file);
            file.on('finish', () => {
                file.close(resolve);
            });
        });
        
        req.on('error', (err) => {
            fs.unlink(outputPath, () => reject(err));
        });
    });
}

async function extractSourceFiles(mapFile, outputDir) {
    const mapData = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
    let fileCount = 0;
    const manifestPaths = [];
    
    // Create all directories first
    mapData.sources.forEach(source => {
        const filePath = normalizePath(source);
        const fullPath = path.join(outputDir, filePath);
        fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    });
    
    // Write files
    mapData.sources.forEach((source, i) => {
        const content = mapData.sourcesContent[i];
        if (!content) return;
        
        const filePath = normalizePath(source);
        const fullPath = path.join(outputDir, filePath);
        fs.writeFileSync(fullPath, content);
        fileCount++;
        
        // Check if this looks like a dependency manifest
        const filename = path.basename(filePath).toLowerCase();
        if (DEPENDENCY_MANIFEST_PATTERNS.some(pattern => pattern.test(filename))) {
            manifestPaths.push(filePath);
        }
    });
    
    return { fileCount, manifestPaths };
}

function normalizePath(sourcePath) {
    return sourcePath
        .replace(/^(webpack|bundle|app):\/\//, '')
        .replace(/^\/?~/, 'node_modules/')
        .replace(/^\/?(node_modules|deps|vendor|lib)\//, '$1/')
        .replace(/^\/?src\//, 'src/');
}

main();
