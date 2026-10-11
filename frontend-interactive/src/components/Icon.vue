<script setup>
import { computed } from 'vue';
const props = defineProps({ name: String, size: { default: 20 } });
const paths = {
  spark: 'M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3z',
  chat: 'M21 11.5a8.5 8.5 0 01-8.5 8.5H4l-1 1V11.5A8.5 8.5 0 0121 11.5z M7 10h10 M7 14h6',
  calendar: 'M7 3v4 M17 3v4 M3 9h18 M5 5h14a2 2 0 012 2v12a2 2 0 01-2 2H5a2 2 0 01-2-2V7a2 2 0 012-2z M7 13h3 M14 13h3 M7 17h3',
  list: 'M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01',
  user: 'M16 7a4 4 0 11-8 0 4 4 0 018 0z M4 21v-2a8 8 0 0116 0v2',
  doc: 'M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8l-6-6z M14 2v6h6 M8 12h8 M8 16h8',
  monitor: 'M4 3h16a1 1 0 011 1v12a1 1 0 01-1 1H4a1 1 0 01-1-1V4a1 1 0 011-1z M8 21h8 M12 17v4',
  chart: 'M3 3v18h18 M7 17v-5 M12 17V7 M17 17V4',
  building: 'M4 21V3h16v18 M1 21h22 M8 7h1 M15 7h1 M8 11h1 M15 11h1 M9 21v-5h6v5',
  settings: 'M12 8a4 4 0 110 8 4 4 0 010-8z M12 2v3 M12 19v3 M2 12h3 M19 12h3 M5 5l2 2 M17 17l2 2 M5 19l2-2 M17 7l2-2',
  book: 'M3 3h7a3 3 0 012 3v15a3 3 0 00-3-3H3V3z M21 3h-7a3 3 0 00-2 3v15a3 3 0 013-3h6V3z',
  shield: 'M12 2l9 4v6c0 6-9 10-9 10S3 18 3 12V6l9-4z M8 12l3 3 5-6',
  arrow: 'M5 12h14 M14 7l5 5-5 5',
  chevron: 'M9 5l7 7-7 7',
  search: 'M21 21l-5-5 M18 10a8 8 0 11-16 0 8 8 0 0116 0z',
  plus: 'M12 5v14 M5 12h14',
  clock: 'M21 12a9 9 0 11-18 0 9 9 0 0118 0z M12 7v5l3 2',
  check: 'M5 12l4 4L19 6',
  close: 'M6 6l12 12 M6 18L18 6',
  menu: 'M4 6h16 M4 12h16 M4 18h16',
  info: 'M21 12a9 9 0 11-18 0 9 9 0 0118 0z M12 11v6 M12 7h.01',
  lock: 'M6 10h12a2 2 0 012 2v7a2 2 0 01-2 2H6a2 2 0 01-2-2v-7a2 2 0 012-2z M8 10V6a4 4 0 018 0v4 M12 14v3',
  reset: 'M3 11a9 9 0 111 6 M3 3v8h8',
  logout: 'M9 3H4v18h5 M10 12h11 M17 8l4 4-4 4',
  heart: 'M20.8 4.6a5.5 5.5 0 00-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 00-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 000-7.8z',
  alert: 'M12 3L2 21h20L12 3z M12 10v5 M12 18h.01',
  download: 'M12 3v12 M7 10l5 5 5-5 M3 16v5h18v-5'
};
const path = computed(() => paths[props.name] || paths.doc);
</script>
<template><svg :width="size" :height="size" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path :d="path"/></svg></template>
