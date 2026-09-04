import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct ProjectsContractTests {
    @Test func projectDTOMapsStableMetadataAndNullConversationMembership() throws {
        let projectData = Data(
            """
            {
              "_id":"project-1","name":"Research","description":"Notes and threads",
              "conversationCount":3,"lastConversationAt":"2026-08-18T10:30:00Z",
              "lastConversationId":"conversation-9","createdAt":"2026-08-01T09:00:00Z",
              "updatedAt":"2026-08-18T10:30:00Z","futureMetadata":{"tier":"team"}
            }
            """.utf8
        )
        let project = try JSONDecoder().decode(LibreChatProjectDTO.self, from: projectData).domainModel()
        #expect(project.id == ProjectID(rawValue: "project-1"))
        #expect(project.name == "Research")
        #expect(project.description == "Notes and threads")
        #expect(project.conversationCount == 3)
        #expect(project.lastConversationID == ConversationID(rawValue: "conversation-9"))
        #expect(project.lastConversationAt != nil)

        let assignmentData = Data(
            """
            {
              "conversation":{"conversationId":"conversation-9","title":"Plan","chatProjectId":null},
              "previousProjectId":"project-1","projectId":null
            }
            """.utf8
        )
        let assignment = try JSONDecoder()
            .decode(LibreChatProjectAssignmentDTO.self, from: assignmentData)
            .domainModel()
        #expect(assignment.conversation.projectID == nil)
        #expect(assignment.previousProjectID == ProjectID(rawValue: "project-1"))
        #expect(assignment.projectID == nil)
    }

    @Test func projectPageDecodesCursorAndConversationMapsProjectMembership() throws {
        let pageData = Data(
            """
            {"projects":[{"_id":"project-1","name":"Inbox","conversationCount":0,
            "lastConversationAt":null,"lastConversationId":null}],"nextCursor":"opaque==cursor"}
            """.utf8
        )
        let page = try JSONDecoder().decode(LibreChatProjectPageDTO.self, from: pageData).domainModel()
        #expect(page.projects.count == 1)
        #expect(page.projects[0].lastConversationAt == nil)
        #expect(page.projects[0].lastConversationID == nil)
        #expect(page.nextCursor == "opaque==cursor")

        let conversation = try JSONDecoder().decode(
            LibreChatConversationDTO.self,
            from: Data(#"{"conversationId":"conversation-1","title":"Thread","chatProjectId":"project-1"}"#.utf8)
        ).domainModel()
        #expect(conversation.projectID == ProjectID(rawValue: "project-1"))
    }

    @Test func projectListUsesPinnedCursorAndQueryContract() {
        let request = LibreChatProjectsAPI.list(
            .init(
                cursor: "opaque==cursor",
                limit: 50,
                sortBy: .lastConversationAt,
                sortDirection: .descending,
                search: "  research plans  "
            )
        )

        #expect(request.method == .get)
        #expect(request.path == "api/projects")
        #expect(request.queryItems == [
            URLQueryItem(name: "cursor", value: "opaque==cursor"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "sortBy", value: "lastConversationAt"),
            URLQueryItem(name: "sortDirection", value: "desc"),
            URLQueryItem(name: "search", value: "research plans")
        ])
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func projectMutationFactoriesUseExactMethodsPathsAndBodies() throws {
        let projectID = ProjectID(rawValue: "507f1f77bcf86cd799439011")
        let conversationID = ConversationID(rawValue: "conversation-1")

        let create = try LibreChatProjectsAPI.create(.init(name: "Research", description: "Q3"))
        #expect(create.method == .post)
        #expect(create.path == "api/projects")
        #expect(try bodyObject(create)["name"] as? String == "Research")
        #expect(try bodyObject(create)["description"] as? String == "Q3")

        let read = LibreChatProjectsAPI.project(id: projectID)
        #expect(read.method == .get)
        #expect(read.path == "api/projects/507f1f77bcf86cd799439011")

        let update = try LibreChatProjectsAPI.update(id: projectID, input: .init(name: "Updated"))
        #expect(update.method == .patch)
        #expect(update.path == read.path)
        #expect(try bodyObject(update)["name"] as? String == "Updated")
        #expect(try bodyObject(update)["description"] == nil)

        let clearDescription = try LibreChatProjectsAPI.update(
            id: projectID,
            input: .init(description: "")
        )
        #expect(try bodyObject(clearDescription)["description"] as? String == "")

        let delete = LibreChatProjectsAPI.delete(id: projectID)
        #expect(delete.method == .delete)
        #expect(delete.path == read.path)
        #expect(delete.retryPolicy == .never)

        let assign = try LibreChatProjectsAPI.assign(conversationID: conversationID, projectID: projectID)
        #expect(assign.method == .put)
        #expect(assign.path == "api/projects/conversations/conversation-1")
        #expect(try bodyObject(assign)["projectId"] as? String == projectID.rawValue)

        let unassign = try LibreChatProjectsAPI.assign(conversationID: conversationID, projectID: nil)
        #expect(unassign.method == .put)
        let unassignBody = try bodyObject(unassign)
        #expect(Set(unassignBody.keys) == Set(["projectId"]))
        #expect(unassignBody["projectId"] is NSNull)
    }

    private func bodyObject<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
