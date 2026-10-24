<script>
import WootDropdownItem from 'shared/components/ui/dropdown/DropdownItem.vue';
import WootDropdownMenu from 'shared/components/ui/dropdown/DropdownMenu.vue';
import Avatar from 'next/avatar/Avatar.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    WootDropdownItem,
    WootDropdownMenu,
    Avatar,
    NextButton,
  },

  props: {
    options: {
      type: Array,
      default: () => [],
    },
    selectedItems: {
      type: Array,
      default: () => [],
    },
    hasThumbnail: {
      type: Boolean,
      default: true,
    },
    inputPlaceholder: {
      type: String,
      default: 'Search',
    },
    noSearchResult: {
      type: String,
      default: 'No results found',
    },
    searchKeys: {
      type: Array,
      default: () => ['name'],
    },
    groupBy: {
      type: String,
      default: '',
    },
    noGroupLabel: {
      type: String,
      default: '',
    },
  },
  emits: ['select'],

  data() {
    return {
      search: '',
    };
  },

  computed: {
    filteredOptions() {
      const searchTerm = this.search.toLowerCase();
      return this.options.filter(option => {
        return this.searchKeys.some(key => {
          const value = option[key];
          return value?.toLowerCase().includes(searchTerm);
        });
      });
    },
    groupedOptions() {
      if (!this.groupBy) {
        return null;
      }
      const groups = {};
      this.filteredOptions.forEach(option => {
        const groupKey = option[this.groupBy] || this.noGroupLabel;
        if (!groups[groupKey]) {
          groups[groupKey] = [];
        }
        groups[groupKey].push(option);
      });
      return groups;
    },
    noResult() {
      return this.filteredOptions.length === 0 && this.search !== '';
    },
  },

  mounted() {
    this.focusInput();
  },

  methods: {
    onclick(option) {
      this.$emit('select', option);
    },
    focusInput() {
      this.$refs.searchbar.focus();
    },
    isActive(option) {
      return this.selectedItems.some(item => item && option.id === item.id);
    },
  },
};
</script>

<template>
  <div class="dropdown-wrap">
    <div class="flex-auto flex-grow-0 flex-shrink-0 mb-2 max-h-8">
      <input
        ref="searchbar"
        v-model="search"
        type="text"
        class="search-input"
        autofocus="true"
        :placeholder="inputPlaceholder"
      />
    </div>
    <div class="flex items-start justify-start flex-auto overflow-auto mt-2">
      <div class="w-full max-h-[10rem]">
        <WootDropdownMenu>
          <!-- Grouped options -->
          <template v-if="groupedOptions">
            <template
              v-for="(groupOptions, groupName, index) in groupedOptions"
              :key="groupName"
            >
              <hr
                v-if="index > 0"
                class="my-2 border-t border-n-weak"
              />
              <li class="px-2.5 py-1 text-xs text-n-slate-10 font-medium">
                {{ groupName }}
              </li>
              <WootDropdownItem
                v-for="option in groupOptions"
                :key="option.id"
              >
                <NextButton
                  slate
                  :variant="isActive(option) ? 'faded' : 'ghost'"
                  trailing-icon
                  :icon="isActive(option) ? 'i-lucide-check' : ''"
                  class="w-full !px-2.5"
                  @click="() => onclick(option)"
                >
                  <div
                    class="flex items-center justify-between w-full min-w-0 gap-2"
                  >
                    <span
                      class="my-0 overflow-hidden text-sm leading-4 whitespace-nowrap text-ellipsis"
                      :title="option.name"
                    >
                      {{ option.name }}
                    </span>
                  </div>
                  <Avatar
                    v-if="hasThumbnail"
                    :src="option.thumbnail"
                    :name="option.name"
                    :status="option.availability_status"
                    :size="24"
                    hide-offline-status
                    rounded-full
                  />
                </NextButton>
              </WootDropdownItem>
            </template>
          </template>
          <!-- Ungrouped options (default behavior) -->
          <template v-else>
            <WootDropdownItem
              v-for="option in filteredOptions"
              :key="option.id"
            >
              <NextButton
                slate
                :variant="isActive(option) ? 'faded' : 'ghost'"
                trailing-icon
                :icon="isActive(option) ? 'i-lucide-check' : ''"
                class="w-full !px-2.5"
                @click="() => onclick(option)"
              >
                <div
                  class="flex items-center justify-between w-full min-w-0 gap-2"
                >
                  <span
                    class="my-0 overflow-hidden text-sm leading-4 whitespace-nowrap text-ellipsis"
                    :title="option.name"
                  >
                    {{ option.name }}
                  </span>
                </div>
                <Avatar
                  v-if="hasThumbnail"
                  :src="option.thumbnail"
                  :name="option.name"
                  :status="option.availability_status"
                  :size="24"
                  hide-offline-status
                  rounded-full
                />
              </NextButton>
            </WootDropdownItem>
          </template>
        </WootDropdownMenu>
        <h4
          v-if="noResult"
          class="w-full justify-center items-center flex text-n-slate-10 py-2 px-2.5 overflow-hidden whitespace-nowrap text-ellipsis text-sm"
        >
          {{ noSearchResult }}
        </h4>
      </div>
    </div>
  </div>
</template>

<style lang="scss" scoped>
.dropdown-wrap {
  @apply w-full flex flex-col max-h-[12.5rem];
}

.search-input {
  @apply m-0 w-full border border-solid border-transparent h-8 text-sm text-n-slate-12 rounded-md focus:border-n-brand bg-n-background dark:bg-n-background;
}

.multiselect-dropdown--item {
  @apply justify-between w-full;

  &.active {
    @apply bg-n-slate-2 dark:bg-n-solid-3 border-n-weak/50 dark:border-n-weak font-medium;
  }

  &:hover {
    @apply bg-n-slate-2 dark:bg-n-solid-3 text-n-slate-12;
  }
}
</style>
