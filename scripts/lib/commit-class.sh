#!/usr/bin/env bash
# scripts/lib/commit-class.sh — conventional-commit subject classifier (HIMMEL-587).
# Factored from scripts/gen-changelog.sh so the changelog generator and the
# doc-freshness detector classify commit subjects identically.
# cc_classify <subject> → echoes one of: feat | fix | changed | other
cc_classify() {
    case "$1" in
        feat:*|feat\(*) printf 'feat' ;;
        fix:*|fix\(*)   printf 'fix' ;;
        chore:*|chore\(*|refactor:*|refactor\(*|docs:*|docs\(*|test:*|test\(*)
                        printf 'changed' ;;
        *)              printf 'other' ;;
    esac
}
