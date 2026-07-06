import { en } from "./en.js";
import { zhHans } from "./zh-Hans.js";
const locales = {
    en,
    zh: zhHans,
    "zh-Hans": zhHans,
};
// Resolve short language tags to canonical BCP 47 forms.
// Based on CLDR likely subtags: zh → zh-Hans-CN
// https://www.unicode.org/cldr/charts/latest/supplemental/likely_subtags.html
const CANONICAL = {
    "en": "en",
    "zh": "zh-Hans",
    "zh-Hans": "zh-Hans",
};
let currentLanguage = "en";
export function setLanguage(lang) {
    currentLanguage = lang;
}
export function getLanguage() {
    return currentLanguage;
}
// https://www.rfc-editor.org/info/bcp47
export function getCanonicalLanguage() {
    return CANONICAL[currentLanguage] ?? "en";
}
// https://www.unicode.org/reports/tr11/
export function isCjkLanguage() {
    return getCanonicalLanguage() === "zh-Hans";
}
export function t(key) {
    const canon = getCanonicalLanguage();
    return locales[canon]?.[key] ?? locales.en[key] ?? key;
}
//# sourceMappingURL=index.js.map