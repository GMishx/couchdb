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

import io.dropwizard.jackson.JsonSnakeCase;

@JsonSnakeCase
public class DoubleRange extends Range<Double> {

    public DoubleRange() {
    }

    public DoubleRange(String name, Double min, boolean minInclusive, Double max, boolean maxInclusive) {
        super(name, min, minInclusive, max, maxInclusive);
    }

}