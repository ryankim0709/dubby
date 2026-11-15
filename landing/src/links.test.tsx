import { cleanup, render } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, test } from 'vitest';
import App from './App';
import { GRADING_CONTRACT_URL, REPO_URL } from './content';

afterEach(cleanup);

const allowedExternal: readonly string[] = [REPO_URL, GRADING_CONTRACT_URL];

describe('destinations', (): void => {
  test('external links point only to the public repository', (): void => {
    expect(REPO_URL).toBe('https://github.com/ryankim0709/dubby');
    expect(GRADING_CONTRACT_URL).toBe(
      'https://github.com/ryankim0709/dubby/blob/main/docs/grading-contract.md',
    );

    render(<App />);
    const hrefs: string[] = Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href]')).map(
      (link: HTMLAnchorElement): string => link.getAttribute('href') ?? '',
    );
    const external: string[] = hrefs.filter((href: string): boolean => !href.startsWith('#'));

    expect(external.length).toBeGreaterThan(0);
    external.forEach((href: string): void => {
      expect(allowedExternal).toContain(href);
    });
  });

  test('external links open safely', (): void => {
    render(<App />);
    document
      .querySelectorAll<HTMLAnchorElement>('a[href^="http"]')
      .forEach((link: HTMLAnchorElement): void => {
        expect(link.getAttribute('rel')).toBe('noreferrer noopener');
        expect(link.getAttribute('target')).not.toBe('_blank');
      });
  });

  test('every in-page anchor resolves to an element', (): void => {
    render(<App />);
    const anchors: HTMLAnchorElement[] = Array.from(
      document.querySelectorAll<HTMLAnchorElement>('a[href^="#"]'),
    );
    expect(anchors.length).toBeGreaterThan(5);
    anchors.forEach((link: HTMLAnchorElement): void => {
      const id: string = (link.getAttribute('href') ?? '').slice(1);
      expect(document.getElementById(id), `#${id}`).not.toBeNull();
    });
  });

  test('has no forms, inputs, mailto, tel, or store links', (): void => {
    render(<App />);

    expect(document.querySelector('form, input, textarea, select')).toBeNull();
    expect(
      document.querySelector('a[href^="mailto:"], a[href^="tel:"], a[href*="apps.apple.com"]'),
    ).toBeNull();
    expect(document.querySelector('a[href*="testflight"]')).toBeNull();
  });

  test('makes no claims about things that do not exist', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    const steps: HTMLElement[] = Array.from(document.querySelectorAll<HTMLElement>('[role="tab"]'));
    for (const step of steps) {
      await user.click(step);
    }
    const text: string = document.body.textContent ?? '';
    expect(text).not.toMatch(/waitlist|sign ?up|join the|pre-?order|pricing|per month|free trial/i);
    expect(text).not.toMatch(/testflight|app store|download now|available now/i);
    expect(text).not.toMatch(
      /testimonial|\d[\d,.]*\s?(users|learners|downloads)|\brated\b|\bstars?\b/i,
    );
    expect(text).not.toMatch(/clon(e|ing)|deepfake|actor.?s voice/i);
  });
});
