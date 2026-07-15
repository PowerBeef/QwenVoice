#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const websiteRoot = path.resolve(scriptDir, "..");
const repositoryRoot = path.resolve(websiteRoot, "..");

const walk = (root, suffixes) => {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) return walk(target, suffixes);
    return suffixes.some((suffix) => entry.name.endsWith(suffix)) ? [target] : [];
  });
};

export const validateText = ({ indexHTML, sources, publicFacts, publicRoot }) => {
  const errors = [];
  const combined = sources.map(({ text }) => text).join("\n");
  const visibleVersion = publicFacts?.stableMacRelease?.version;
  const publicDisplayVersion = visibleVersion?.replace(/\.0$/, "");
  if (!visibleVersion || !indexHTML.includes(`Vocello ${publicDisplayVersion}`)) {
    errors.push("index metadata does not match the public stable Mac release");
  }
  for (const [label, pattern] of [
    ["English document language", /<html\s+lang=["']en["']/],
    ["description metadata", /<meta\s+[^>]*name=["']description["']/s],
    ["viewport metadata", /<meta\s+[^>]*name=["']viewport["']/s],
    ["Open Graph title", /<meta\s+[^>]*property=["']og:title["']/s],
    ["Open Graph URL", /<meta\s+[^>]*property=["']og:url["']/s],
    ["Open Graph image alternative", /<meta\s+[^>]*property=["']og:image:alt["']/s],
    ["Twitter card", /<meta\s+[^>]*name=["']twitter:card["']/s],
    ["canonical URL", /<link\s+[^>]*rel=["']canonical["']/s],
    ["robots directive", /<meta\s+[^>]*name=["']robots["']/s],
    ["document title", /<title>/],
  ]) {
    if (!pattern.test(indexHTML)) errors.push(`index.html is missing ${label}`);
  }
  for (const { name, text } of sources) {
    if (text.includes("—")) errors.push(`${name} contains a prohibited em dash`);
    if (/faster than (?:real[ -]?time|playback)/i.test(text)) {
      errors.push(`${name} contains an unqualified performance claim`);
    }
    for (const match of text.matchAll(/<img\b([^>]*?)\/?\s*>/gs)) {
      if (!/\balt\s*=/.test(match[1])) errors.push(`${name} contains an image without alt text`);
    }
    for (const match of text.matchAll(/<a\b([^>]*target=["']_blank["'][^>]*)>/gs)) {
      if (!/rel=["'][^"']*noreferrer/.test(match[1])) {
        errors.push(`${name} contains a target=_blank link without rel=noreferrer`);
      }
    }
  }

  const ids = new Set([...combined.matchAll(/\bid=["'`]([^"'`]+)["'`]/g)].map((match) => match[1]));
  for (const match of combined.matchAll(/href=["'`]#([^"'`]+)["'`]/g)) {
    if (!ids.has(match[1])) errors.push(`internal link #${match[1]} has no static target`);
  }
  for (const match of combined.matchAll(/(?:src|shot):?\s*=\s*["'`]\/?(assets\/[^"'`]+)["'`]/g)) {
    if (!fs.existsSync(path.join(publicRoot, match[1]))) errors.push(`missing public asset: ${match[1]}`);
  }
  return [...new Set(errors)].sort();
};

export const validateRepository = () => {
  const sources = walk(path.join(websiteRoot, "src"), [".jsx", ".js"]).map((file) => ({
    name: path.relative(repositoryRoot, file),
    text: fs.readFileSync(file, "utf8"),
  }));
  return validateText({
    indexHTML: fs.readFileSync(path.join(websiteRoot, "index.html"), "utf8"),
    sources,
    publicFacts: JSON.parse(fs.readFileSync(path.join(repositoryRoot, "config/public-product-facts.json"), "utf8")),
    publicRoot: path.join(websiteRoot, "public"),
  });
};

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const errors = validateRepository();
  if (errors.length) {
    errors.forEach((error) => console.error(`error: ${error}`));
    process.exitCode = 1;
  } else {
    console.log("Website contract: PASS");
  }
}
