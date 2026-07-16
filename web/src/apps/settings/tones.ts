
import marimba    from '@/assets/tones/ringtones/marimba.mp3';
import reflection from '@/assets/tones/ringtones/reflection.mp3';
import classic    from '@/assets/tones/ringtones/classic.mp3';
import signal     from '@/assets/tones/ringtones/signal.mp3';
import hold       from '@/assets/tones/ringtones/hold.mp3';
import aria       from '@/assets/tones/ringtones/aria.mp3';
import mirage     from '@/assets/tones/ringtones/mirage.mp3';
import twinkle    from '@/assets/tones/ringtones/twinkle.mp3';

import bell    from '@/assets/tones/notification/bell.mp3';
import chime   from '@/assets/tones/notification/chime.mp3';
import bloom   from '@/assets/tones/notification/bloom.mp3';
import pop     from '@/assets/tones/notification/pop.mp3';
import bubble  from '@/assets/tones/notification/bubble.mp3';
import glimmer from '@/assets/tones/notification/glimmer.mp3';
import note    from '@/assets/tones/notification/note.mp3';
import tap     from '@/assets/tones/notification/tap.mp3';

export type ToneKind = 'ringtone' | 'notification';

export interface Tone {
    id:   string;
    name: string;
    url:  string;
}

export const RINGTONES: Tone[] = [
    { id: 'marimba',    name: 'Marimba',    url: marimba },
    { id: 'reflection', name: 'Reflection', url: reflection },
    { id: 'classic',    name: 'Classic',    url: classic },
    { id: 'signal',     name: 'Signal',     url: signal },
    { id: 'hold',       name: 'Hold',       url: hold },
    { id: 'aria',       name: 'Aria',       url: aria },
    { id: 'mirage',     name: 'Mirage',     url: mirage },
    { id: 'twinkle',    name: 'Twinkle',    url: twinkle },
];

export const NOTIFICATION_TONES: Tone[] = [
    { id: 'bell',    name: 'Bell',    url: bell },
    { id: 'chime',   name: 'Chime',   url: chime },
    { id: 'bloom',   name: 'Bloom',   url: bloom },
    { id: 'pop',     name: 'Pop',     url: pop },
    { id: 'bubble',  name: 'Bubble',  url: bubble },
    { id: 'glimmer', name: 'Glimmer', url: glimmer },
    { id: 'note',    name: 'Note',    url: note },
    { id: 'tap',     name: 'Tap',     url: tap },
];

export const DEFAULT_RINGTONE     = 'marimba';
export const DEFAULT_NOTIFICATION = 'note';

export interface CustomTone {
    id:   string;
    name: string;
    url:  string;
}

export function resolveTone(kind: ToneKind, id: string, custom: CustomTone[]): { url: string; name: string } {
    const list = listFor(kind);
    const builtin = list.find(t => t.id === id);
    if (builtin) return { url: builtin.url, name: builtin.name };
    const c = custom.find(t => t.id === id);
    if (c) return { url: c.url, name: c.name };
    const fallback = kind === 'ringtone' ? DEFAULT_RINGTONE : DEFAULT_NOTIFICATION;
    const def = list.find(t => t.id === fallback) ?? list[0];
    return { url: def.url, name: def.name };
}

function listFor(kind: ToneKind): Tone[] {
    return kind === 'ringtone' ? RINGTONES : NOTIFICATION_TONES;
}

export function toneUrl(kind: ToneKind, id: string): string {
    const list = listFor(kind);
    const fallback = kind === 'ringtone' ? DEFAULT_RINGTONE : DEFAULT_NOTIFICATION;
    return (list.find(t => t.id === id) ?? list.find(t => t.id === fallback) ?? list[0]).url;
}
