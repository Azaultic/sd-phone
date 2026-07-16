import { Play, Search } from 'lucide-react';

import { t } from '@/i18n';
import { DISCOVER, fmt } from './data';

const SB_H = 54;

const TRENDS = ['#lossantos', 'sunset', 'night drive', 'phonk', 'beach day', 'lofi'];

export function Discover() {
    return (
        <div className="flex h-full flex-col bg-black text-white">
            <div className="shrink-0" style={{ height: SB_H }} />

            <div className="shrink-0 px-3 pb-2">
                <div className="flex items-center gap-2 rounded-full bg-white/10 px-4 py-2.5">
                    <Search className="h-4 w-4 text-white/60" strokeWidth={2.4} />
                    <input
                        placeholder={t('vibez.search', 'Search')}
                        className="w-full bg-transparent text-[14px] text-white placeholder:text-white/45 outline-none"
                    />
                </div>
                <div className="no-scrollbar mt-3 flex gap-2 overflow-x-auto">
                    {TRENDS.map(t => (
                        <span key={t} className="shrink-0 rounded-full bg-white/8 px-3 py-1.5 text-[12px] text-white/80">{t}</span>
                    ))}
                </div>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto no-scrollbar px-0.5 pb-24">
                <div className="grid grid-cols-3 gap-0.5">
                    {DISCOVER.map(tile => (
                        <div key={tile.id} className="relative aspect-[9/16] overflow-hidden bg-white/5">
                            <img src={tile.img} alt="" draggable={false} className="h-full w-full object-cover" />
                            <div className="pointer-events-none absolute inset-x-0 bottom-0 h-12 bg-gradient-to-t from-black/70 to-transparent" />
                            <div className="absolute bottom-1.5 left-1.5 flex items-center gap-1 text-white drop-shadow">
                                <Play className="h-3 w-3" fill="#fff" strokeWidth={0} />
                                <span className="text-[11px] font-semibold">{fmt(tile.views)}</span>
                            </div>
                        </div>
                    ))}
                </div>
            </div>
        </div>
    );
}
