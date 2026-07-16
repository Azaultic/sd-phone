import { isValidElement, type ReactNode } from 'react';
import type { LucideIcon } from 'lucide-react';

export function EmptyState({ icon: Icon, title, subtitle, subtitleClassName, action, center = false, circle = true, circleClassName }: {
    icon:                LucideIcon | ReactNode;
    title:               string;
    subtitle?:           string;
    subtitleClassName?:  string;
    action?:             ReactNode;
    center?:             boolean;
    circle?:             boolean;
    circleClassName?:    string;
}) {
    const glyph = isValidElement(Icon)
        ? Icon
        : (() => {
            const Comp = Icon as LucideIcon;
            return <Comp className="h-8 w-8 text-ios-gray" strokeWidth={2} />;
        })();
    return (
        <div className={`flex flex-col items-center text-center ${center ? 'h-full justify-center' : 'pt-24'}`}>
            {circle ? (
                <div className={`flex h-16 w-16 items-center justify-center rounded-full ${circleClassName ?? 'bg-[#e5e5e5] dark:bg-[#1C1C1E]'}`}>
                    {glyph}
                </div>
            ) : glyph}
            <div className="mt-4 text-[21px] font-bold text-black dark:text-white">{title}</div>
            {subtitle && (
                <p className={`mt-2 max-w-[290px] text-[16px] leading-snug ${subtitleClassName ?? 'text-black/60 dark:text-white/60'}`}>{subtitle}</p>
            )}
            {action && <div className="mt-5">{action}</div>}
        </div>
    );
}
