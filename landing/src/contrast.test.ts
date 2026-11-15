import { describe, expect, test } from 'vitest';
import css from './styles.css?raw';

const token = (name: string): string => {
  const match: RegExpMatchArray | null = css.match(new RegExp(`--${name}:\\s*(#[0-9a-f]{6})`, 'i'));
  if (match?.[1] === undefined) throw new Error(`Missing color token --${name}`);
  return match[1];
};

const luminance = (hex: string): number => {
  const [r, g, b] = [1, 3, 5].map((start: number): number => {
    const channel: number = parseInt(hex.slice(start, start + 2), 16) / 255;
    return channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  }) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};

const ratio = (foreground: string, background: string): number => {
  const [light, dark]: number[] = [luminance(foreground), luminance(background)].sort(
    (a: number, b: number): number => b - a,
  ) as [number, number];
  return (light + 0.05) / (dark + 0.05);
};

const textPairs: readonly (readonly [string, string])[] = [
  ['text', 'background'],
  ['secondary', 'background'],
  ['muted', 'background'],
  ['accent-text', 'background'],
  ['text', 'surface'],
  ['secondary', 'surface'],
  ['muted', 'surface'],
  ['accent-text', 'surface'],
  ['text', 'raised'],
  ['text', 'track'],
  ['muted', 'raised'],
  ['on-accent', 'accent'],
  ['on-accent', 'accent-text'],
  ['on-accent', 'accent-hover'],
  ['on-accent-soft', 'accent'],
  ['text', 'on-accent'],
];

const graphicPairs: readonly (readonly [string, string])[] = [
  ['accent', 'background'],
  ['accent', 'surface'],
  ['muted', 'background'],
  ['muted', 'surface'],
  ['graphic', 'surface'],
  ['graphic', 'background'],
  ['accent-text', 'surface'],
];

describe('WCAG 2.2 contrast of the color tokens', (): void => {
  test.each(textPairs)(
    'text %s on %s is at least 4.5:1',
    (foreground: string, background: string): void => {
      expect(ratio(token(foreground), token(background))).toBeGreaterThanOrEqual(4.5);
    },
  );

  test.each(graphicPairs)(
    'graphic %s on %s is at least 3:1',
    (foreground: string, background: string): void => {
      expect(ratio(token(foreground), token(background))).toBeGreaterThanOrEqual(3);
    },
  );
});
