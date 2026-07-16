import { t } from '@/i18n';
import type { Business } from './data';
import { Stars } from '@/ui/Stars';

export function BusinessLogo({ b, size = 46, radius = 12, font = 20 }: { b: Business; size?: number; radius?: number; font?: number }) {
    return (
        <div
            className="flex shrink-0 items-center justify-center font-bold text-white"
            style={{ width: size, height: size, borderRadius: radius, background: b.logo, fontSize: font }}
        >
            {b.name.charAt(0).toUpperCase()}
        </div>
    );
}

export function BusinessCard({ b, onOpen }: { b: Business; onOpen: () => void }) {
    return (
        <button
            type="button"
            onClick={onOpen}
            className="flex w-full items-center gap-3 px-4 py-2.5 text-left active:bg-black/5 dark:active:bg-white/10"
        >
            <BusinessLogo b={b} />
            <div className="min-w-0 flex-1">
                <p className="truncate text-[15px] font-semibold text-black dark:text-white">{b.name}</p>
                <div className="mt-0.5 flex items-center gap-1.5">
                    <Stars value={b.rating} size={13} />
                    <span className="text-[12px] text-black/50 dark:text-white/50">
                        {b.count > 0 ? `${b.rating.toFixed(1)} · ${b.count} ${b.count === 1 ? t('review.reviewWord', 'review') : t('review.reviewsWord', 'reviews')}` : t('review.noReviewsYet', 'No reviews yet')}
                    </span>
                </div>
                <p className="mt-0.5 truncate text-[12px] text-black/45 dark:text-white/45">{b.category} · {b.address}</p>
            </div>
            <svg width="18" height="18" viewBox="0 0 24 24" className="shrink-0 text-black/25 dark:text-white/25" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M9 6l6 6-6 6" />
            </svg>
        </button>
    );
}
