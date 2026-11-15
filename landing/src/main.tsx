import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import '@fontsource-variable/manrope';
import App from './App';
import './styles.css';

const rootElement: HTMLElement | null = document.getElementById('root');

if (rootElement === null) {
  throw new Error('Cannot mount DubIt: the root element is missing from index.html.');
}

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
