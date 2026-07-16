import { useState } from 'react';
import { Trophy } from 'lucide-react';

export interface GameToast { key: string; name: string; }

export function useGameToasts() {
    const [toasts, setToasts] = useState<GameToast[]>([]);
    function pushToast(name: string) {
        const key = `${name}-${Date.now()}`;
        setToasts(list => [...list, { key, name }]);
        setTimeout(() => setToasts(list => list.filter(x => x.key !== key)), 2600);
    }
    return { toasts, pushToast };
}

export function GameToasts({ toasts, top, color, pop }: {
    toasts: GameToast[];
    top: number;
    color: string;
    pop: string;
}) {
    return (
        <div className="pointer-events-none absolute inset-x-0 z-[60] flex flex-col items-center gap-1.5" style={{ top }}>
            {toasts.map(toast => (
                <div
                    key={toast.key}
                    className="flex items-center gap-2 rounded-full px-3.5 py-1.5 text-[13px] font-bold text-white shadow-lg"
                    style={{ backgroundColor: color, animation: pop }}
                >
                    <Trophy className="h-[13px] w-[13px]" strokeWidth={2.6} />
                    {toast.name}
                </div>
            ))}
        </div>
    );
}
