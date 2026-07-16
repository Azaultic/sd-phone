
interface GlyphProps {
    className?: string;
}

export function PhoneGlyph({ className }: GlyphProps) {
    return (
        <svg viewBox="0 0 24 24" className={className} fill="currentColor" aria-hidden>
            <path
                d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"
                stroke="currentColor"
                strokeWidth="0.5"
                strokeLinejoin="round"
            />
        </svg>
    );
}

export function MailGlyph({ className }: GlyphProps) {
    return (
        <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <rect x="2.5" y="4.5" width="19" height="15" rx="2.6" />
            <path d="M3 7l8 5.2a2 2 0 0 0 2 0L21 7" />
        </svg>
    );
}

export function MessageGlyph({ className }: GlyphProps) {
    return (
        <svg viewBox="5 5 50 50" className={className} fill="currentColor" aria-hidden>
            <g transform="scale(0.907099) translate(59.483067,-145.8456)">
                <path d="m -26.410149,157.29606 a 24.278298,20.222157 0 0 0 -24.278105,20.22202 24.278298,20.222157 0 0 0 11.79463,17.31574 27.365264,20.222157 0 0 1 -4.245218,5.94228 23.85735,20.222157 0 0 0 9.86038,-3.87367 24.278298,20.222157 0 0 0 6.868313,0.83768 24.278298,20.222157 0 0 0 24.2781059,-20.22203 24.278298,20.222157 0 0 0 -24.2781059,-20.22202 z" />
            </g>
        </svg>
    );
}
