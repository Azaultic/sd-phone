import type { ReactNode } from 'react';

import { CHERRY } from './data';

export function PinkButton({ onClick, disabled, className = '', children }: {
    onClick:    () => void;
    disabled?:  boolean;
    className?: string;
    children:   ReactNode;
}) {
    return (
        <button
            type="button"
            onClick={onClick}
            disabled={disabled}
            className={`rounded-full px-10 py-3.5 text-[19px] font-semibold text-white active:opacity-80 disabled:opacity-60 ${className}`}
            style={{ background: CHERRY.pink }}
        >
            {children}
        </button>
    );
}

export function PhotoStack({ photos, activeIdx, name }: {
    photos:    string[];
    activeIdx: number;
    name:      string;
}) {
    if (photos.length === 0) {
        return (
            <div className="flex h-full w-full items-center justify-center" style={{ background: `linear-gradient(165deg, ${CHERRY.pink}, #C81E5A)` }}>
                <span className="text-[96px] font-extrabold text-white/90">{name.slice(0, 1).toUpperCase()}</span>
            </div>
        );
    }
    return (
        <>
            {photos.map((src, i) => (
                <img
                    key={`${src}-${i}`}
                    src={src}
                    alt={i === activeIdx ? name : ''}
                    draggable={false}
                    className="absolute inset-0 h-full w-full object-cover transition-opacity duration-300"
                    style={{
                        opacity: i === activeIdx ? 1 : 0,
                        transform: 'translateZ(0)',
                        willChange: 'opacity',
                        backfaceVisibility: 'hidden',
                    }}
                />
            ))}
        </>
    );
}
