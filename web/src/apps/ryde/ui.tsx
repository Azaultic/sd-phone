import type { ReactNode } from 'react';
import { Car as CarIcon, Star } from 'lucide-react';

import { usePinStyle } from '@/apps/maps/MapView';

export { MapView } from '@/apps/maps/MapView';

export function Pin({ x, y, z = 10, children }: { x: number; y: number; z?: number; children: ReactNode }) {
    const style = usePinStyle(x, y);
    return <div style={{ ...style, zIndex: z, pointerEvents: 'none' }} className="flex flex-col items-center">{children}</div>;
}

export function PickupDot() {
    return <span className="block h-3.5 w-3.5 rounded-full border-2 border-white bg-[#22c55e] shadow" />;
}
export function DropoffPin() {
    return <span className="block h-3.5 w-3.5 rounded-[3px] border-2 border-white bg-black shadow dark:bg-white dark:border-black" />;
}
export function CarMarker({ color = '#111' }: { color?: string }) {
    return (
        <span
            className="flex h-[30px] w-[30px] items-center justify-center rounded-full border-[2.5px] border-white"
            style={{ background: color, boxShadow: '0 2px 6px rgba(0,0,0,0.35)' }}
        >
            <CarIcon className="h-[16px] w-[16px] text-white" strokeWidth={2.4} />
        </span>
    );
}

export function BigButton({ children, onClick, disabled, variant = 'primary' }: {
    children: ReactNode; onClick?: () => void; disabled?: boolean; variant?: 'primary' | 'secondary';
}) {
    const cls = variant === 'primary'
        ? 'bg-black text-white dark:bg-white dark:text-black'
        : 'bg-black/[0.06] text-black dark:bg-white/10 dark:text-white';
    return (
        <button onClick={onClick} disabled={disabled} className={`w-full rounded-[14px] py-3.5 text-[16px] font-bold disabled:opacity-40 ${cls}`}>
            {children}
        </button>
    );
}

export function RatingPill({ rating }: { rating: number }) {
    return (
        <span className="inline-flex items-center gap-1 text-[13px] font-semibold text-black dark:text-white">
            <Star className="h-3.5 w-3.5" style={{ color: '#FF9600', fill: '#FF9600' }} />{rating.toFixed(2)}
        </span>
    );
}
