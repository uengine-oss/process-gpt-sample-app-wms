<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const router = useRouter()
const email = ref('')
const password = ref('')
const error = ref('')
const loading = ref(false)

async function onSubmit() {
  error.value = ''
  loading.value = true
  try {
    await auth.signIn(email.value, password.value)
    await router.push('/overview')
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="login-page">
    <form class="login-card" @submit.prevent="onSubmit">
      <h1>WMS Sample App</h1>
      <p class="hint">demo users, e.g. buyer-a@demo.local / Demo1234!</p>
      <label>
        Email
        <input v-model="email" type="email" required autocomplete="username" />
      </label>
      <label>
        Password
        <input v-model="password" type="password" required autocomplete="current-password" />
      </label>
      <div v-if="error" class="error-banner">{{ error }}</div>
      <button class="primary" type="submit" :disabled="loading">
        {{ loading ? 'Signing in…' : 'Sign in' }}
      </button>
    </form>
  </div>
</template>

<style scoped>
.login-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg);
}
.login-card {
  background: white;
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 2rem;
  width: 320px;
  display: flex;
  flex-direction: column;
  gap: 0.9rem;
}
h1 {
  margin: 0;
  font-size: 1.25rem;
}
.hint {
  margin: 0;
  color: var(--muted);
  font-size: 0.8rem;
}
label {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
  font-size: 0.85rem;
  color: var(--muted);
}
input {
  padding: 0.5rem 0.6rem;
  border: 1px solid var(--line);
  border-radius: 6px;
  font-size: 0.95rem;
}
</style>
