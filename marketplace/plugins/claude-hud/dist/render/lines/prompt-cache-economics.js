import { label } from '../colors.js';
import { t } from '../../i18n/index.js';
import { getModelPricing, resolveEffectiveCachePricing, resolveSessionCost, formatUsd } from '../../cost.js';
import { formatCacheTokens, computeCacheHitPercent, computeCacheNetUsd, formatCacheUsd, } from '../../cache-economics.js';
const EMPTY_TOKENS = {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
};
const PLACEHOLDER = '—';
function formatNet(reads, writes, ctx) {
    const pricing = getModelPricing(ctx.stdin);
    if (!pricing) {
        return PLACEHOLDER;
    }
    const { inputUsdPerMillion, cacheReadUsdPerMillion, cacheWriteUsdPerMillion } = resolveEffectiveCachePricing(pricing);
    const readSavingsRate = (inputUsdPerMillion - cacheReadUsdPerMillion) / 1_000_000;
    const writeOverheadRate = (cacheWriteUsdPerMillion - inputUsdPerMillion) / 1_000_000;
    const net = computeCacheNetUsd(reads, writes, readSavingsRate, writeOverheadRate);
    const sign = net >= 0 ? '+' : '-';
    return `${sign}$${formatCacheUsd(net)}`;
}
function formatRow(rowLabel, reads, writes, inputs, ctx) {
    const rFmt = formatCacheTokens(reads);
    const wFmt = formatCacheTokens(writes);
    const hitPct = computeCacheHitPercent(reads, inputs);
    const netPart = formatNet(reads, writes, ctx);
    return `${label(rowLabel)} r:${rFmt} w:${wFmt} hit:${hitPct}% net ${netPart}`;
}
export function renderPromptCacheEconomicsLine(ctx) {
    if (!ctx.config?.display?.showPromptCacheEconomics) {
        return null;
    }
    const sessionTokens = ctx.transcript.sessionTokens ?? EMPTY_TOKENS;
    const sessionRow = formatRow(t('label.cacheEconomicsSession'), sessionTokens.cacheReadTokens, sessionTokens.cacheCreationTokens, sessionTokens.inputTokens, ctx);
    const costDisplay = resolveSessionCost(ctx.stdin, sessionTokens);
    const costPart = costDisplay ? formatUsd(costDisplay.totalUsd) : PLACEHOLDER;
    const sessionLine = `${sessionRow}  ${label(t('label.cacheEconomicsCost'))} ${costPart}`;
    const all = ctx.allSessionsCacheEconomics;
    if (!all) {
        return sessionLine;
    }
    const allLine = formatRow(t('label.cacheEconomicsAll'), all.reads, all.writes, all.inputs, ctx);
    return `${sessionLine}\n${allLine}`;
}
//# sourceMappingURL=prompt-cache-economics.js.map