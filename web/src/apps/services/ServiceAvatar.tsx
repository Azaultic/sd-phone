export function ServiceAvatar({ color, emoji, size = 50 }: { color: string; emoji: string; size?: number }) {
    return (
        <div
            className="flex shrink-0 items-center justify-center rounded-full leading-none"
            style={{ background: color, width: size, height: size, fontSize: Math.round(size * 0.52) }}
        >
            {emoji}
        </div>
    );
}
