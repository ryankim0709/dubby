import { describe, expect, test } from 'vitest';
import html from '../index.html?raw';
import css from './styles.css?raw';

const doc: Document = new DOMParser().parseFromString(html, 'text/html');
const meta = (selector: string): string | null =>
  doc.querySelector(selector)?.getAttribute('content') ?? null;

describe('index.html metadata', (): void => {
  test('describes the page for search and sharing', (): void => {
    expect(doc.documentElement.lang).toBe('en');
    expect(doc.title).toContain('DubIt');
    expect(meta('meta[name="description"]')).toMatch(/in development/i);
    expect(meta('meta[property="og:title"]')).toContain('DubIt');
    expect(meta('meta[property="og:description"]')).toBeTruthy();
    expect(meta('meta[property="og:type"]')).toBe('website');
    expect(meta('meta[property="og:site_name"]')).toBe('DubIt');
    expect(meta('meta[name="twitter:card"]')).toBe('summary');
    expect(meta('meta[name="viewport"]')).toContain('width=device-width');
  });

  test('does not name a domain the project does not own', (): void => {
    expect(doc.querySelector('link[rel="canonical"]')).toBeNull();
    expect(doc.querySelector('meta[property="og:url"]')).toBeNull();
    expect(doc.querySelector('meta[property="og:image"]')).toBeNull();
    expect(html).not.toMatch(/https?:\/\/(?!github\.com\/ryankim0709\/dubby)/);
  });
});

describe('stylesheet', (): void => {
  test('removes essential motion for visitors who ask for reduced motion', (): void => {
    const block: string = css.slice(css.indexOf('@media (prefers-reduced-motion: reduce)'));
    expect(block).toContain('scroll-behavior: auto');
    expect(block).toContain('animation: none');
    expect(block).toContain('transition: none');
  });

  test('draws a visible keyboard focus ring', (): void => {
    expect(css).toMatch(/:focus-visible\s*{[^}]*outline:\s*3px solid/);
  });
});
