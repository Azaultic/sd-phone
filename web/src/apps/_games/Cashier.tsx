import { useState } from 'react';
import { ArrowRight, Coins, Landmark } from 'lucide-react';

import { buyChips, sellChips, type ChipState } from './chipsApi';
import { t } from '@/i18n';

const fmt = (n: number) => Math.floor(n).toLocaleString('en-US');
const QUICK = [100, 500, 1000, 5000];
const CHIP_TINT = '#E8C463';

export function Cashier({ chips, bank, accent, game, onChange }: {
    chips: number; bank: number; accent: string; game: string; onChange: (s: ChipState) => void;
}) {
    const [mode, setMode] = useState<'buy' | 'sell'>('buy');
    const [amount, setAmount] = useState(0);
    const [busy, setBusy] = useState(false);
    const [error, setError] = useState<string | null>(null);

    const max = mode === 'buy' ? bank : chips;
    const tooMuch = amount > max;

    async function confirm() {
        if (busy || amount <= 0 || tooMuch) return;
        setBusy(true); setError(null);
        const r = await (mode === 'buy' ? buyChips(amount, game) : sellChips(amount, game));
        setBusy(false);
        if (r.ok && r.state) { onChange(r.state); setAmount(0); }
        else setError(r.message || t('games.somethingWrong', 'Something went wrong'));
    }

    return (
        <div className="flex min-h-0 flex-1 flex-col px-5 pt-3" style={{ paddingBottom: 'calc(var(--safe-bottom) + 20px)' }}>
            <div className="flex gap-3">
                <Balance icon={<Coins className="h-[16px] w-[16px]" strokeWidth={2.4} />} label={t('games.chipsLabel', 'Chips')} value={chips} tint={CHIP_TINT} />
                <Balance icon={<Landmark className="h-[16px] w-[16px]" strokeWidth={2.4} />} label={t('games.bank', 'Bank')} value={`$${fmt(bank)}`} />
            </div>

            <div className="mt-4 flex rounded-[12px] p-0.5" style={{ background: 'rgba(0,0,0,0.3)' }}>
                {(['buy', 'sell'] as const).map(m => {
                    const active = mode === m;
                    return (
                        <button key={m} type="button" onClick={() => { setMode(m); setAmount(0); setError(null); }} className="flex-1 rounded-[10px] py-2 text-[15px] font-bold capitalize transition" style={{ color: active ? '#fff' : 'rgba(255,255,255,0.6)', background: active ? accent : 'transparent' }}>
                            {m} {t('games.chips', 'chips')}
                        </button>
                    );
                })}
            </div>

            <div className="mt-4 flex items-center justify-center gap-2 text-[13px] font-semibold text-white/55">
                {mode === 'buy'
                    ? <><span>{t('games.bank', 'Bank')}</span><ArrowRight className="h-[15px] w-[15px]" strokeWidth={2.4} /><span style={{ color: CHIP_TINT }}>{t('games.chipsLabel', 'Chips')}</span></>
                    : <><span style={{ color: CHIP_TINT }}>{t('games.chipsLabel', 'Chips')}</span><ArrowRight className="h-[15px] w-[15px]" strokeWidth={2.4} /><span>{t('games.bank', 'Bank')}</span></>}
                <span className="text-white/30">{t('games.oneChipRate', '· 1 chip = $1')}</span>
            </div>

            <div className="mt-3 rounded-[18px] p-4" style={{ background: 'rgba(255,255,255,0.07)' }}>
                <div className="flex items-baseline justify-between">
                    <span className="text-[12px] font-semibold uppercase tracking-wide text-white/45">{t('games.amount', 'Amount')}</span>
                    <span className={`text-[12px] font-semibold ${tooMuch ? 'text-[#FF8A80]' : 'text-white/45'}`}>{mode === 'buy' ? t('games.bank', 'Bank') : t('games.chipsLabel', 'Chips')} {fmt(max)}</span>
                </div>
                <div className="mt-1 flex items-center gap-2">
                    <Coins className="h-[20px] w-[20px] shrink-0" strokeWidth={2.4} style={{ color: CHIP_TINT }} />
                    <input
                        value={amount === 0 ? '' : String(amount)}
                        onChange={e => { setError(null); setAmount(Math.max(0, Math.floor(Number(e.target.value.replace(/\D/g, '')) || 0))); }}
                        inputMode="numeric"
                        placeholder="0"
                        className="min-w-0 flex-1 bg-transparent text-[30px] font-black tabular-nums text-white outline-none placeholder-white/25"
                    />
                </div>
                <div className="mt-3 flex flex-wrap gap-2">
                    {QUICK.map(q => (
                        <button key={q} type="button" onClick={() => { setError(null); setAmount(a => a + q); }} className="rounded-full px-3 py-1.5 text-[13px] font-bold text-white active:opacity-70" style={{ background: 'rgba(0,0,0,0.3)' }}>+{fmt(q)}</button>
                    ))}
                    <button type="button" onClick={() => { setError(null); setAmount(max); }} className="rounded-full px-3 py-1.5 text-[13px] font-extrabold active:opacity-80" style={{ background: 'rgba(0,0,0,0.3)', color: accent }}>{t('games.max', 'MAX')}</button>
                </div>
            </div>

            {error && <div className="mt-3 text-center text-[13px] font-medium text-[#FF8A80]">{error}</div>}

            <button
                type="button"
                onClick={confirm}
                disabled={busy || amount <= 0 || tooMuch}
                className="mt-auto w-full rounded-[16px] py-3.5 text-center text-[17px] font-bold text-white active:opacity-80 disabled:opacity-40"
                style={{ background: accent }}
            >
                {tooMuch ? (mode === 'buy' ? t('games.notEnoughInBank', 'Not enough in the bank') : t('games.notEnoughChips', 'Not enough chips')) : mode === 'buy' ? t('games.buySummary', 'Buy {n} chips · ${n}', { n: fmt(amount) }) : t('games.sellSummary', 'Sell {n} chips · ${n}', { n: fmt(amount) })}
            </button>
        </div>
    );
}

function Balance({ icon, label, value, tint }: { icon: React.ReactNode; label: string; value: number | string; tint?: string }) {
    return (
        <div className="flex-1 rounded-[16px] px-4 py-3" style={{ background: 'rgba(255,255,255,0.06)' }}>
            <span className="flex items-center gap-1.5 text-[12px] font-semibold uppercase tracking-wide text-white/45" style={tint ? { color: tint } : undefined}>{icon}{label}</span>
            <div className="mt-1 text-[22px] font-black tabular-nums text-white">{typeof value === 'number' ? fmt(value) : value}</div>
        </div>
    );
}
