#!/usr/bin/env node
const fs = require("fs")
const path = require("path")
const https = require("https")
const { execSync } = require("child_process")
const vm = require("vm")

// Config - Expanded patterns for dependency manifests
const DEPENDENCY_PATTERNS = [
    /dependencies?/i,
    /bender/i,
    /manifest/i,
    /modules?/i,
    /components?/i,
    /packages?/i,
    /vendor/i,
    /libs?/i,
    /externals?/i,
    /include/i,
    /require/i,
    /imports?/i,
]

async function main() {
    try {
        const targetDir = process.argv[2] || "."
        if (!fs.existsSync(targetDir)) throw new Error("Directory not found")

        console.log(`🔍 Scanning for dependency manifests in: ${targetDir}`)

        // Find all potential manifests using content-based detection
        const manifests = findManifestFiles(targetDir)
        if (manifests.length === 0) {
            console.log("ℹ️ No dependency manifests found")
            return
        }

        console.log("\n📦 Found potential dependency manifests:")
        manifests.forEach((m) =>
            console.log(`  - ${path.relative(targetDir, m.path)} (${m.type})`)
        )

        const outputDir = path.join(targetDir, "external-dependencies")
        fs.mkdirSync(outputDir, { recursive: true })

        console.log(`\n📁 Dependency output: ${outputDir}`)

        // Process each manifest
        for (const manifest of manifests) {
            try {
                console.log(`\n🔍 Processing: ${path.basename(manifest.path)}`)
                const dependencies = extractDependencies(manifest)

                if (dependencies.length === 0) {
                    console.log("  ℹ️ No dependencies found in this manifest")
                    continue
                }

                console.log(`  🗂️ Found ${dependencies.length} dependencies`)

                let downloaded = 0
                for (const dep of dependencies) {
                    try {
                        const result = await downloadDependency(dep, outputDir)
                        if (result) {
                            console.log(`  ✓ ${dep.name}@${dep.version}`)
                            downloaded++
                        }
                    } catch (e) {
                        console.log(`  ✗ ${dep.name}: ${e.message}`)
                    }
                }

                console.log(
                    `  ✅ Downloaded ${downloaded}/${dependencies.length} dependencies`
                )
            } catch (e) {
                console.log(`  ❌ Failed to process: ${e.message}`)
            }
        }

        console.log("\n🚀 Dependency download complete!")
    } catch (error) {
        console.error("❌ Error:", error.message)
        process.exit(1)
    }
}

// --- Enhanced Utility Functions ---

/**
 * Finds manifest files by both name and content analysis
 */
function findManifestFiles(dir) {
    const manifests = []
    const scannedFiles = new Set()

    function scanDirectory(currentDir) {
        const entries = fs.readdirSync(currentDir, { withFileTypes: true })

        for (const entry of entries) {
            const fullPath = path.join(currentDir, entry.name)
            const relativePath = path.relative(dir, fullPath)

            // Avoid processing the same file multiple times
            if (scannedFiles.has(relativePath)) continue
            scannedFiles.add(relativePath)

            if (entry.isDirectory()) {
                // Skip common directories that won't contain manifests
                if (/(node_modules|dist|build|\.git|\.cache)/i.test(entry.name))
                    continue
                scanDirectory(fullPath)
            } else {
                // Check by filename pattern
                const filenameMatch = DEPENDENCY_PATTERNS.some((pattern) =>
                    pattern.test(entry.name)
                )

                // Check by content (first 1KB)
                let contentMatch = false
                try {
                    const content = fs.readFileSync(fullPath, "utf8", 0, 1024)
                    contentMatch =
                        DEPENDENCY_PATTERNS.some((pattern) =>
                            pattern.test(content)
                        ) ||
                        /(dependencies|depVersions|require|import)/i.test(
                            content
                        )
                } catch {}

                if (filenameMatch || contentMatch) {
                    const type = filenameMatch ? "filename" : "content"
                    manifests.push({ path: fullPath, type })
                }
            }
        }
    }

    scanDirectory(dir)
    return manifests
}

/**
 * Extracts dependencies from various manifest formats
 */
function extractDependencies(manifest) {
    const { path: manifestPath } = manifest
    const content = fs.readFileSync(manifestPath, "utf8")
    const dependencies = []

    // 1. Try to parse as JavaScript object (like HubSpot's bender format)
    try {
        const sandbox = { exports: {}, module: { exports: {} } }
        vm.createContext(sandbox)

        // Try different assignment patterns
        const scripts = [
            `(function() { 
                var __WEBPACK_NAMESPACE_OBJECT__; 
                ${content};
                return __WEBPACK_NAMESPACE_OBJECT__; 
            })()`,
            `(function() { 
                ${content};
                return module.exports || exports; 
            })()`,
        ]

        for (const script of scripts) {
            try {
                const result = vm.runInContext(script, sandbox)
                if (result?.bender?.depVersions) {
                    const bender = result.bender
                    Object.entries(bender.depVersions).forEach(
                        ([name, version]) => {
                            dependencies.push({
                                name,
                                version,
                                pathPrefix: bender.depPathPrefixes?.[name],
                                baseUrl:
                                    bender.staticDomain ||
                                    bender.staticDomainPrefix,
                                source: "bender",
                            })
                        }
                    )
                    return dependencies
                }
            } catch {}
        }
    } catch {}

    // 2. Try to parse as JSON (package.json format)
    try {
        const data = JSON.parse(content)
        if (data.dependencies) {
            Object.entries(data.dependencies).forEach(([name, version]) => {
                dependencies.push({ name, version, source: "package.json" })
            })
        }
        return dependencies
    } catch {}

    // 3. Try to parse as YAML (if we detect --- or : syntax)
    try {
        if (/^---|:/.test(content.trim())) {
            const yaml = require("js-yaml")
            const data = yaml.load(content)
            if (data.dependencies) {
                Object.entries(data.dependencies).forEach(([name, version]) => {
                    dependencies.push({ name, version, source: "yaml" })
                })
            }
            return dependencies
        }
    } catch {}

    // 4. Try to extract via regex (fallback method)
    const regexPatterns = [
        // JavaScript object patterns
        /['"]([^'"]+)['"]\s*:\s*['"]([^'"]+)['"]/g,
        /(\w+)Version\s*:\s*['"]([^'"]+)['"]/g,

        // Common dependency formats
        /(?:dependencies|depVersions)\s*:\s*{([^}]+)}/,
        /(?:dependencies|depVersions)\s*=\s*{([^}]+)}/,
    ]

    for (const pattern of regexPatterns) {
        let match
        while ((match = pattern.exec(content)) !== null) {
            const depContent = match[1] || match[0]
            const depMatches = depContent.matchAll(
                /(['"]?)(\w[\w-@\/]+)\1\s*:\s*['"]([^'"]+)['"]/g
            )

            for (const depMatch of depMatches) {
                dependencies.push({
                    name: depMatch[2],
                    version: depMatch[3],
                    source: "regex",
                })
            }
        }
    }

    return dependencies
}

/**
 * Smart dependency downloader with multiple fallback strategies
 */
async function downloadDependency(dep, outputDir) {
    const filename = `${dep.name.replace(/\//g, "_")}@${dep.version}.js`
    const outputPath = path.join(outputDir, filename)

    // 1. HubSpot CDN pattern
    if (dep.source === "bender" && dep.baseUrl && dep.pathPrefix) {
        const url = `${dep.baseUrl}${dep.pathPrefix}/bundles/${dep.name}.js`
        return tryDownload(url, outputPath)
    }

    // 2. Standard CDN patterns
    const cdnPatterns = [
        `${dep.baseUrl || "https://cdn.example.com"}/${dep.name}@${
            dep.version
        }/dist/${dep.name}.js`,
        `${dep.baseUrl || "https://cdn.example.com"}/${dep.name}@${
            dep.version
        }/${dep.name}.js`,
        `${dep.baseUrl || "https://cdn.example.com"}/${
            dep.pathPrefix || dep.name
        }/${dep.name}.js`,
    ]

    // 3. Public CDNs
    const publicCdns = [
        `https://unpkg.com/${dep.name}@${dep.version}`,
        `https://cdn.jsdelivr.net/npm/${dep.name}@${dep.version}`,
        `https://bundle.run/${dep.name}@${dep.version}`,
    ]

    // Combine all possible URLs
    const urls = [
        ...cdnPatterns,
        ...publicCdns.map((url) => `${url}/dist/${dep.name}.min.js`),
        ...publicCdns.map((url) => `${url}/dist/${dep.name}.js`),
        ...publicCdns.map((url) => `${url}/${dep.name}.js`),
        ...publicCdns.map((url) => `${url}/bundle.js`),
    ]

    // Try each URL with fallback
    for (const url of urls) {
        if (await tryDownload(url, outputPath)) {
            return true
        }
    }

    throw new Error("No valid download URL found")
}

async function tryDownload(url, outputPath) {
    return new Promise((resolve) => {
        const cleanedUrl = url
            .replace(/([^:])\/\//g, "$1/")
            .replace(":/", "://")
        const parsedUrl = new URL(
            cleanedUrl.startsWith("//") ? `https:${cleanedUrl}` : cleanedUrl
        )

        const req = https.get(parsedUrl, (res) => {
            // Follow redirects
            if (
                [301, 302, 307, 308].includes(res.statusCode) &&
                res.headers.location
            ) {
                return tryDownload(res.headers.location, outputPath).then(
                    resolve
                )
            }

            if (res.statusCode !== 200) {
                req.destroy()
                return resolve(false)
            }

            const file = fs.createWriteStream(outputPath)
            res.pipe(file)
            file.on("finish", () => {
                file.close()
                // Verify we got JS content
                const content = fs.readFileSync(outputPath, "utf8", 0, 100)
                if (/(function|var|const|let|=>|class)/.test(content)) {
                    resolve(true)
                } else {
                    fs.unlinkSync(outputPath)
                    resolve(false)
                }
            })
        })

        req.on("error", () => resolve(false))
        req.setTimeout(5000, () => {
            req.destroy()
            resolve(false)
        })
    })
}

// Install YAML parser if needed
try {
    require.resolve("js-yaml")
} catch {
    console.log("⚠️ Installing js-yaml for YAML support...")
    execSync("npm install js-yaml", { stdio: "inherit" })
}

main()
