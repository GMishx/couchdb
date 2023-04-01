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

package org.apache.couchdb.nouveau.lucene9;

import java.util.concurrent.ExecutorService;

import org.apache.couchdb.nouveau.LuceneBundle;
import org.apache.couchdb.nouveau.NouveauApplicationConfiguration;
import org.apache.couchdb.nouveau.lucene9.core.Lucene9Module;
import org.apache.couchdb.nouveau.lucene9.core.ParallelSearcherFactory;
import org.apache.couchdb.nouveau.lucene9.health.AnalyzeHealthCheck;
import org.apache.couchdb.nouveau.lucene9.health.IndexHealthCheck;
import org.apache.couchdb.nouveau.lucene9.resources.AnalyzeResource;
import org.apache.couchdb.nouveau.lucene9.resources.IndexResource;
import org.apache.lucene.search.SearcherFactory;

import io.dropwizard.core.setup.Environment;

public final class Lucene9Bundle extends LuceneBundle {

    @Override
    public void run(final NouveauApplicationConfiguration configuration, final Environment environment)
            throws Exception {

        // Serialization classes
        environment.getObjectMapper().registerModule(new Lucene9Module());

        // AnalyzeResource
        environment.jersey().register(new AnalyzeResource());

        // IndexResource
        final ExecutorService executorService = environment.lifecycle().executorService("nouveau-lucene9-%d").build();
        final SearcherFactory searcherFactory = new ParallelSearcherFactory(executorService);
        final IndexResource indexResource = new IndexResource(indexManager, searcherFactory);
        environment.jersey().register(indexResource);

        // Health checks
        environment.healthChecks().register("analyze9", new AnalyzeHealthCheck());
        environment.healthChecks().register("index9", new IndexHealthCheck(indexResource));
    }

}