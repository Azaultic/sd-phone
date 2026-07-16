import { UP_COLOR, DOWN_COLOR } from './data';

export function Sparkline({ data, width = 56, height = 26, strokeWidth = 2, color, fill = false }: {
    data:         number[];
    width?:       number;
    height?:      number;
    strokeWidth?: number;
    color?:       string;
    fill?:        boolean;
}) {
    if (!data || data.length < 2) return <svg width={width} height={height} aria-hidden />;

    const min = Math.min(...data);
    const max = Math.max(...data);
    const span = max - min || 1;
    const pad = strokeWidth / 2;

    const x = (i: number) => (i / (data.length - 1)) * (width - strokeWidth) + pad;
    const y = (v: number) => height - pad - ((v - min) / span) * (height - strokeWidth);

    const line = data.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
    const stroke = color ?? (data[data.length - 1] >= data[0] ? UP_COLOR : DOWN_COLOR);
    const gid = `spk-${Math.round(x(0))}-${Math.round(width)}-${stroke.replace('#', '')}`;

    return (
        <svg width={width} height={height} className="overflow-visible">
            {fill && (
                <>
                    <defs>
                        <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%"   stopColor={stroke} stopOpacity="0.28" />
                            <stop offset="100%" stopColor={stroke} stopOpacity="0" />
                        </linearGradient>
                    </defs>
                    <polygon
                        points={`${pad},${height} ${line} ${(width - pad).toFixed(2)},${height}`}
                        fill={`url(#${gid})`}
                    />
                </>
            )}
            <polyline
                points={line}
                fill="none"
                stroke={stroke}
                strokeWidth={strokeWidth}
                strokeLinecap="round"
                strokeLinejoin="round"
            />
        </svg>
    );
}

export function AreaChart({ data, color, height = 130 }: { data: number[]; color: string; height?: number }) {
    if (!data || data.length < 2) return <div style={{ height }} />;
    const W = 100, H = 40;
    const min = Math.min(...data), max = Math.max(...data), span = max - min || 1;
    const x = (i: number) => (i / (data.length - 1)) * W;
    const y = (v: number) => H - ((v - min) / span) * H;
    const line = data.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
    const gid = `area-${color.replace('#', '')}-${Math.round(height)}`;
    return (
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" style={{ height, width: '100%' }}>
            <defs>
                <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor={color} stopOpacity="0.30" />
                    <stop offset="100%" stopColor={color} stopOpacity="0" />
                </linearGradient>
            </defs>
            <polygon points={`0,${H} ${line} ${W},${H}`} fill={`url(#${gid})`} />
            <polyline points={line} fill="none" stroke={color} strokeWidth={2} vectorEffect="non-scaling-stroke" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
    );
}
