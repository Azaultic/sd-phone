export function formatMoney(n: number, opts: {
    decimals?:   number;
    showSign?:   boolean;
    whole?:      boolean;
    alwaysSign?: boolean;
} = {}): string {
    const decimals = opts.decimals ?? (opts.whole ? 0 : 2);
    const abs = Math.abs(n).toLocaleString('en-US', {
        minimumFractionDigits: decimals,
        maximumFractionDigits: decimals,
    });
    if (n < 0) return `-$${abs}`;
    if (opts.alwaysSign) return `+$${abs}`;
    return opts.showSign && n > 0 ? `+$${abs}` : `$${abs}`;
}
