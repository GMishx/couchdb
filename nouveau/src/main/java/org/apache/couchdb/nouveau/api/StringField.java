//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package org.apache.couchdb.nouveau.api;

import java.util.Objects;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;


import jakarta.validation.constraints.NotNull;

@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public final class StringField extends Field {

    @NotNull
    private final String value;

    private final boolean store;

    private final boolean facet;

    public StringField(@JsonProperty("name") final String name, @JsonProperty("value") final String value,
            @JsonProperty("store") final boolean store, @JsonProperty("facet") final boolean facet) {
        super(name);
        this.value = Objects.requireNonNull(value);
        this.store = store;
        this.facet = facet;
    }

    @JsonProperty
    public String getValue() {
        return value;
    }

    @JsonProperty
    public boolean isStore() {
        return store;
    }

    @JsonProperty
    public boolean isFacet() {
        return facet;
    }

    @Override
    public String toString() {
        return "StringField [name=" + name + ", value=" + value + ", store=" + store + ", facet=" + facet + "]";
    }

}