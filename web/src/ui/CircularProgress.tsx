export function CircularProgress({ progress, size = 24, stroke = 3, className }: {
    progress:   number;
    size?:      number;
    stroke?:    number;
    className?: string;
}) {
    const clamped = Math.max(0, Math.min(1, progress));
    const r       = (size - stroke) / 2;
    const circ    = 2 * Math.PI * r;

    return (
        <svg
            width={size}
            height={size}
            viewBox={`0 0 ${size} ${size}`}
            className={className}
            style={{ transform: 'rotate(-90deg)' }}
        >
            <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="currentColor" strokeOpacity={0.3} strokeWidth={stroke} />
            <circle
                cx={size / 2}
                cy={size / 2}
                r={r}
                fill="none"
                stroke="currentColor"
                strokeWidth={stroke}
                strokeLinecap="round"
                strokeDasharray={circ}
                strokeDashoffset={circ * (1 - clamped)}
                style={{ transition: 'stroke-dashoffset 0.12s linear' }}
            />
        </svg>
    );
}
