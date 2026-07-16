import type { Gender } from './data';

export function GenderBadge({ gender, onPhoto = false }: { gender?: Gender; onPhoto?: boolean }) {
    if (!gender) return null;
    return (
        <span
            className={onPhoto
                ? 'inline-flex shrink-0 items-center rounded-full bg-white/25 px-2.5 py-[3px] text-[13px] font-semibold text-white backdrop-blur'
                : 'inline-flex shrink-0 items-center rounded-full bg-black/[0.07] px-3 py-1 text-[14px] font-semibold text-black/70'}
        >
            {gender}
        </span>
    );
}
