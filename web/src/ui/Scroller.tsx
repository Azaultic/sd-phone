import type { ReactNode } from 'react';

export function Scroller({ children, className = '' }: {
    children: ReactNode;
    className?: string;
}) {
    return (
        <div className={`ios-scrollbar overflow-y-auto ${className}`}>
            {children}
        </div>
    );
}
