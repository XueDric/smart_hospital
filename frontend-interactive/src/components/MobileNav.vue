<script setup>
import { computed } from 'vue';
import Icon from './Icon.vue';
import { ui, role, page, go } from '../store.js';
import { mobileItems, ROLE_LABEL } from '../pages.js';
// 不接收 props：直接订阅 store，导航状态一变本组件自行重渲染。
// 若改成由 App.vue 传 props，父级在 <main> 之后的区块不会重新 patch，导航会卡在首次渲染。
const items = computed(() => mobileItems(role.value, page.value));
</script>
<template>
  <nav class="mobile-bottom" :aria-label="`${ROLE_LABEL[role]}快捷导航`">
    <template v-for="i in items" :key="i.id">
      <a v-if="!i.more" :href="`#/${i.route}`" :class="{ active: i.active }" :aria-current="i.active ? 'page' : undefined" @click.prevent="go(i.id)"><Icon :name="i.icon" :size="21" /><span>{{ i.label }}</span></a>
      <button v-else type="button" aria-label="打开更多页面" @click="ui.mobileNav = true"><Icon :name="i.icon" :size="21" /><span>{{ i.label }}</span></button>
    </template>
  </nav>
</template>
