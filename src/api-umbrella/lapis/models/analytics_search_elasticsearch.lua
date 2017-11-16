local cjson = require "cjson"
local escape_regex = require "api-umbrella.utils.escape_regex"
local http = require "resty.http"
local is_empty = require("pl.types").is_empty
local json_encode = require "api-umbrella.utils.json_encode"
local startswith = require("pl.stringx").startswith

CASE_SENSITIVE_FIELDS = {
  api_key = 1,
  request_ip_city = 1,
}

UPPERCASE_FIELDS = {
  request_method = 1,
  request_ip_country = 1,
  request_ip_region = 1,
}

local _M = {}
_M.__index = _M

local function parse_query_builder(query)
  local query_filter
  if not is_empty(query) then
    local filters = {}
    for _, rule in ipairs(query["rules"]) do
      local filter
      local operator = rule["operator"]
      local field = rule["field"]
      local value = rule["value"]

      if not CASE_SENSITIVE_FIELDS[field] and type(value) == "string" then
        if UPPERCASE_FIELDS[field] then
          value = string.upper(value)
        else
          value = string.lower(value)
        end
      end

      if operator == "equal" or operator == "not_equal" then
        filter = {
          term = {
            [field] = value,
          },
        }
      elseif operator == "not_equal" then
        filter = {
          term = {
            [field] = value,
          },
        }
      elseif operator == "begins_with" or operator == "not_begins_with" then
        filter = {
          prefix = {
            [field] = value,
          },
        }
      elseif operator == "contains" or operator == "not_contains" then
        filter = {
          regexp = {
            [field] = ".*" .. escape_regex(value) .. ".*",
          },
        }
      elseif operator == "is_null" or operator == "is_not_null" then
        filter = {
          exists = {
            field = field,
          },
        }
      elseif operator == "less" then
        filter = {
          range = {
            [field] = {
              lt = tonumber(value),
            },
          },
        }
      elseif operator == "less_or_equal" then
        filter = {
          range = {
            [field] = {
              lte = tonumber(value),
            },
          },
        }
      elseif operator == "greater" then
        filter = {
          range = {
            [field] = {
              gt = tonumber(value),
            },
          },
        }
      elseif operator == "greater_or_equal" then
        filter = {
          range = {
            [field] = {
              gte = tonumber(value),
            },
          },
        }
      elseif operator == "between" then
        filter = {
          range = {
            [field] = {
              gte = tonumber(value[1]),
              lte = tonumber(value[2]),
            },
          },
        }
      else
        error("unknown filter operator: " .. inspect(operator) .. "  (rule: " .. inspect(rule) .. ")")
      end

      if operator == "is_null" or startswith(operator, "not_") then
        filter = {
          bool = {
            must_not = filter,
          }
        }
      end

      table.insert(filters, filter)
    end

    if not is_empty(filters) then
      local condition
      if query["condition"] == "OR" then
        condition = "should"
      else
        condition = "must"
      end

      query_filter = {
        bool = {
          [condition] = filters,
        },
      }
    end
  end

  return query_filter
end

function _M.new(options)
  local self = {
    start_time = assert(options["start_time"]),
    end_time = assert(options["end_time"]),
    interval = options["interval"],
    elasticsearch_host = config["elasticsearch"]["hosts"][1],
    query = {},
    body = {
      query = {
        filtered = {
          query = {
            match_all = {},
          },
          filter = {
            bool = {
              must = {},
              must_not = {},
            },
          },
        },
      },
      sort = {
        { request_at = "desc" },
      },
      aggregations = {},
      size = 0,
      timeout = 90,
    },
  }

  return setmetatable(self, _M)
end

function _M:set_permission_scope(scopes)
  local filter = parse_query_builder(scopes)
  table.insert(self.body["query"]["filtered"]["filter"]["bool"]["must"], filter)
end

function _M:filter_by_time_range()
  table.insert(self.body["query"]["filtered"]["filter"]["bool"]["must"], {
    range = {
      request_at = {
        from = self.start_time,
        to = self.end_time,
      },
    },
  })
end

function _M:set_interval(start_time, end_time)
end

function _M:set_search_query_string(query_string)
  if not is_empty(query_string) then
    self.body["query"]["filtered"]["query"] = {
      query_string = {
        query = query_string,
      },
    }
  end
end

function _M:set_search_filters(query)
  if type(query) == "string" and query ~= "" then
    query = cjson.decode(query)
  end

  local filter = parse_query_builder(query)
  if filter then
    table.insert(self.body["query"]["filtered"]["filter"]["bool"]["must"], filter)
  end
end

function _M:set_offset(offset)
  self.body["from"] = offset
end

function _M:set_limit(limit)
  self.body["size"] = limit
end

function _M:aggregate_by_interval()
  self.body["aggregations"]["hits_over_time"] = {
    date_histogram = {
      field = "request_at",
      interval = self.interval,
      time_zone = config["analytics"]["timezone"],
      min_doc_count = 0,
      extended_bounds = {
        min = self.start_time,
        max = self.end_time,
      },
    },
  }

  if config["elasticsearch"]["api_version"] < 2 then
    self.body["aggregations"]["hits_over_time"]["date_histogram"]["pre_zone_adjust_large_interval"] = true
  end
end

function _M:aggregate_by_term(field, size)
  self.body["aggregations"]["top_" .. field] = {
    terms = {
      field = field,
      size = size,
      shard_size = size * 4,
    },
  }

  self.body["aggregations"]["value_count_" .. field] = {
    value_count = {
      field = field,
    },
  }

  self.body["aggregations"]["missing_" .. field] = {
    missing = {
      field = field,
    },
  }
end

function _M:aggregate_by_cardinality(field)
  self.body["aggregations"]["unique_" .. field] = {
    cardinality = {
      field = field,
      precision_threshold = 100,
    },
  }
end

function _M:aggregate_by_users(size)
  self:aggregate_by_term("user_email", size)
  self:aggregate_by_cardinality("user_email")
end

function _M:aggregate_by_request_ip(size)
  self:aggregate_by_term("request_ip", size)
  self:aggregate_by_cardinality("request_ip")
end

function _M:aggregate_by_response_time_average()
  self.body["aggregations"]["response_time_average"] = {
    avg = {
      field = "response_time",
    },
  }
end

function _M:aggregate_by_drilldown(prefix, size)
  if not size then
    size = 0
  end

  self.body["aggregations"]["drilldown"] = {
    terms = {
      field = "request_hierarchy",
      size = size,
      include = escape_regex(prefix) .. ".*",
    },
  }
end

function _M:aggregate_by_drilldown_over_time(prefix)
  table.insert(self.body["query"]["filtered"]["filter"]["bool"]["must"], {
    prefix = {
      request_hierarchy = prefix,
    },
  })

  self.body["aggregations"]["top_path_hits_over_time"] = {
    terms = {
      field = "request_hierarchy",
      size = 10,
      include = escape_regex(prefix) .. ".*",
    },
    aggregations = {
      drilldown_over_time = {
        date_histogram = {
          field = "request_at",
          interval = self.interval,
          time_zone = config["analytics"]["timezone"],
          min_doc_count = 0,
          extended_bounds = {
            min = self.start_time,
            max = self.end_time,
          },
        },
      },
    },
  }

  self.body["aggregations"]["hits_over_time"] = {
    date_histogram = {
      field = "request_at",
      interval = self.interval,
      time_zone = config["analytics"]["timezone"],
      min_doc_count = 0,
      extended_bounds = {
        min = self.start_time,
        max = self.end_time,
      },
    },
  }

  if config["elasticsearch"]["api_version"] < 2 then
    self.body["aggregations"]["top_path_hits_over_time"]["aggregations"]["drilldown_over_time"]["date_histogram"]["pre_zone_adjust_large_interval"] = true
    self.body["aggregations"]["hits_over_time"]["date_histogram"]["pre_zone_adjust_large_interval"] = true
  end
end

function _M:aggregate_by_user_stats(order)
  self.body["aggregations"]["user_stats"] = {
    terms = {
      field = "user_id",
      size = size,
    },
    aggregations = {
      last_request_at = {
        max = {
          field = "request_at",
        },
      },
    },
  }

  if order then
    self.body["aggregations"]["user_stats"]["terms"]["order"] = order
  end
end

function _M:aggregate_by_region_field(field)
  self.body["aggregations"]["regions"] = {
    terms = {
      field = field,
      size = 500,
    },
  }

  self.body["aggregations"]["missing_regions"] = {
    missing = {
      field = field,
    },
  }
end

function _M:aggregate_by_country()
  return _M.aggregate_by_region_field(self, "request_ip_country")
end

function _M:aggregate_by_region(region)
  if region == "world" then
    return _M.aggregate_by_country(self)
  elseif region == "US" then
    return _M:aggregate_by_country_regions(region)
  else
    local matches, match_err = ngx.re.match(region, [[^(US)-([A-Z]{2})$]], "jo")
    if matches then
      local country = matches[1]
      local state = matches[2]
      return _M:aggregate_by_us_state_cities(country, state)
    else
      if match_err then
        ngx.log(ngx.ERR, "regex error: ", match_err)
      end

      return _M:aggregate_by_country_cities(region)
    end
  end
end

function _M:fetch_results()
  setmetatable(self.body["query"]["filtered"]["filter"]["bool"]["must_not"], cjson.empty_array_mt)
  setmetatable(self.body["query"]["filtered"]["filter"]["bool"]["must"], cjson.empty_array_mt)
  setmetatable(self.body["sort"], cjson.empty_array_mt)

  if is_empty(self.body["aggregations"]) then
    self.body["aggregations"] = nil
  end

  local httpc = http.new()
  local res, err = httpc:request_uri(self.elasticsearch_host .. "/_search", {
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
    },
    query = self.query,
    body = json_encode(self.body),
  })
  local data = cjson.decode(res.body)

  return data
end

function _M:fetch_results_bulk(callback)
  self.query["scroll"] = "10m"

  self.query["sort"] = { "_doc" }
  if config["elasticsearch"]["api_version"] < 2 then
    self.query["sort"] = nil
    self.query["search_type"] = "scan"
  end

  local raw_results = _M.fetch_results(self)
  callback(raw_results["hits"]["hits"])

  local scroll_id
  local httpc = http.new()
  while true do
    scroll_id = raw_results["_scroll_id"]
    local res, err = httpc:request_uri(self.elasticsearch_host .. "/_search/scroll", {
      method = "GET",
      headers = {
        ["Content-Type"] = "application/json",
      },
      body = json_encode({
        scroll = self.query["scroll"],
        scroll_id = scroll_id,
      })
    })
    raw_results = cjson.decode(res.body)

    if not raw_results["hits"] or is_empty(raw_results["hits"]["hits"]) then
      break
    end

    callback(raw_results["hits"]["hits"])
  end

  local res, err = httpc:request_uri(self.elasticsearch_host .. "/_search/scroll", {
    method = "DELETE",
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = json_encode({
      scroll_id = { scroll_id },
    })
  })
  if res.status ~= 200 then
    ngx.log(ngx.ERR, "elasticsearch scroll clear failed: " .. (res.body or ""))
  end
end

return _M
