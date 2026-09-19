/**
 * Shared Type Definitions for macOS Computer Use MCP Server
 */

export interface Point {
  x: number;
  y: number;
}

export interface Size {
  width: number;
  height: number;
}

export interface Bounds extends Point, Size {}

export interface DisplayInfo {
  width: number;
  height: number;
  scale: number;
  pixelWidth: number;
  pixelHeight: number;
}

export interface WindowBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface WindowInfo {
  windowId: number;
  pid: number;
  appName: string;
  title: string;
  isOnScreen?: boolean;
  bounds: WindowBounds;
}

export interface WindowTarget {
  windowId: number;
  pid: number;
  appName: string;
  title: string;
  bounds: WindowBounds;
}

export interface AXSelector {
  role?: string;
  identifier?: string;
  title?: string;
  description?: string;
  query?: string;
  occurrence?: number;
}

export interface AXElementSummary {
  path: number[];
  role: string;
  subrole?: string;
  identifier?: string;
  title?: string;
  description?: string;
  placeholder?: string;
  help?: string;
  valueSettable?: boolean;
  value?: string;
  actions?: string[];
  frame?: WindowBounds;
  settableAttributes?: string[];
}

export interface AXInspectOptions {
  roles?: string[];
  maxDepth?: number;
  maxResults?: number;
  includeValues?: boolean;
  includeSettableAttributes?: boolean;
  selector?: Record<string, any>;
}

export type MatchMode = "exact" | "word" | "prefix" | "substring";

export interface TextMatchItem {
  text: string;
  confidence: number;
  bounds: {
    x: number;
    y: number;
    width: number;
    height: number;
    centerX: number;
    centerY: number;
  };
  lineBounds?: WindowBounds;
  matchedText?: string;
  matchType?: string;
  matchRank?: number;
  querySimilarity?: number;
  globalCoordinates?: Point;
}

export interface ToolAnnotations {
  readOnlyHint?: boolean;
  destructiveHint?: boolean;
  idempotentHint?: boolean;
  openWorldHint?: boolean;
}

export interface ToolTextContent {
  type: "text";
  text: string;
}

export interface ToolImageContent {
  type: "image";
  data: string;
  mimeType: string;
}

export type ToolContentItem = ToolTextContent | ToolImageContent;

export interface ToolResult {
  content: ToolContentItem[];
  isError?: boolean;
  [key: string]: unknown;
}
