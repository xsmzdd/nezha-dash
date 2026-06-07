"use client"

import { createContext, type ReactNode, useContext, useEffect, useMemo, useState } from "react"
import useSWR from "swr"
import type { ServerApi } from "@/lib/drivers/types"
import { getClientPollingInterval } from "@/lib/polling"
import { nezhaFetcher } from "@/lib/utils"

export interface ServerDataWithTimestamp {
  timestamp: number
  data: ServerApi
}

interface ServerDataContextType {
  data: ServerApi | undefined
  error: Error | undefined
  isLoading: boolean
  history: ServerDataWithTimestamp[]
}

const ServerDataContext = createContext<ServerDataContextType | undefined>(undefined)

export const MAX_HISTORY_LENGTH = 8

export function ServerDataProvider({ children }: { children: ReactNode }) {
  const [history, setHistory] = useState<ServerDataWithTimestamp[]>([])

  const refreshInterval = getClientPollingInterval(8000)

  const { data, error, isLoading } = useSWR<ServerApi>("/api/server", nezhaFetcher, {
    refreshInterval,
    dedupingInterval: 6000,
    keepPreviousData: true,
    revalidateOnFocus: false,
    revalidateOnReconnect: false,
  })

  useEffect(() => {
    if (data) {
      setHistory((prev) => {
        const newHistory = [
          {
            timestamp: Date.now(),
            data: data,
          },
          ...prev,
        ].slice(0, MAX_HISTORY_LENGTH)

        return newHistory
      })
    }
  }, [data])

  const contextValue = useMemo(
    () => ({ data, error, isLoading, history }),
    [data, error, isLoading, history],
  )

  return <ServerDataContext.Provider value={contextValue}>{children}</ServerDataContext.Provider>
}

export function useServerData() {
  const context = useContext(ServerDataContext)
  if (context === undefined) {
    throw new Error("useServerData must be used within a ServerDataProvider")
  }
  return context
}
