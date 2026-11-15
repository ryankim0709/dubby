import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, test } from 'vitest';
import App from './App';

afterEach(cleanup);

test('visitors can explore each stage of the dubbing walkthrough', async (): Promise<void> => {
  const user = userEvent.setup();
  render(<App />);

  const sceneButton = screen.getByRole('button', { name: /Find your scene/ });
  const voiceButton = screen.getByRole('button', { name: /Make every line yours/ });
  const replayButton = screen.getByRole('button', { name: /Play it back/ });
  const preview = screen.getByRole('region', { name: 'Experience preview' });

  expect(voiceButton.getAttribute('aria-pressed')).toBe('true');

  await user.click(sceneButton);
  expect(sceneButton.getAttribute('aria-pressed')).toBe('true');
  expect(voiceButton.getAttribute('aria-pressed')).toBe('false');
  expect(preview.textContent).toContain('Every good story');

  await user.click(replayButton);
  expect(replayButton.getAttribute('aria-pressed')).toBe('true');
  expect(sceneButton.getAttribute('aria-pressed')).toBe('false');
  expect(preview.textContent).toContain('Same scene. A whole new you.');

  await user.tab({ shift: true });
  await user.keyboard('{Enter}');
  expect(voiceButton.getAttribute('aria-pressed')).toBe('true');
});
